# frozen_string_literal: true
# typed: true

require 'pathname'

module Tapioca
  class Generator < Thor::Shell::Color
    extend(T::Sig)

    class GemNameError < RuntimeError
      attr_reader :gem_name

      def initialize(message, gem_name)
        super(message)
        @gem_name = gem_name
      end
    end

    sig { returns(Pathname) }
    attr_reader :outdir
    sig { returns(T.nilable(String)) }
    attr_reader :prerequire
    sig { returns(T.nilable(String)) }
    attr_reader :postrequire
    sig { returns(T.nilable(String)) }
    attr_reader :gemfile

    sig do
      params(
        outdir: String,
        prerequire: T.nilable(String),
        postrequire: T.nilable(String),
        gemfile:  T.nilable(String)
      ).void
    end
    def initialize(outdir:, prerequire:, postrequire:, gemfile:)
      @outdir = T.let(Pathname.new(outdir), Pathname)
      @prerequire = T.let(prerequire, T.nilable(String))
      @postrequire = T.let(postrequire, T.nilable(String))
      @gemfile = T.let(gemfile, T.nilable(String))
      super()
    end

    sig { params(gem_names: T::Array[String]).void }
    def build_gem_rbis(gem_names)
      require_gem_file

      gems_to_generate(gem_names).map do |gem|
        say("Processing '#{gem.name}' gem:", :green)
        indent do
          compile_rbi(gem)
          puts
        end
      end

      say("All operations performed in working directory.", [:green, :bold])
      say("Please review changes and commit them.", [:green, :bold])
    end

    sig { void }
    def sync_rbis_with_gemfile
      anything_done = [
        perform_removals,
        perform_additions,
      ].any?

      if anything_done
        say("All operations performed in working directory.", [:green, :bold])
        say("Please review changes and commit them.", [:green, :bold])
      else
        say("No operations performed, all RBIs are up-to-date.", [:green, :bold])
      end

      puts
    end

    private

    sig { returns(Gemfile) }
    def bundle
      @bundle ||= Gemfile.new(gemfile: gemfile)
    end

    sig { returns(String) }
    def bundle_path
      File.dirname(bundle.gemfile.path)
    end

    sig { returns(Compilers::SymbolTableCompiler) }
    def compiler
      @compiler ||= Compilers::SymbolTableCompiler.new
    end

    sig { void }
    def require_gem_file
      bundle.require_bundle(prerequire, postrequire)
    end

    sig { returns(T::Hash[String, String]) }
    def existing_rbis
      @existing_rbis ||= Dir.glob("*@*.rbi", T.unsafe(base: outdir))
        .map { |f| File.basename(f, ".*").split('@') }
        .to_h
    end

    sig { returns(T::Hash[String, String]) }
    def expected_rbis
      @expected_rbis ||= bundle.dependencies
        .map { |gem| [gem.name, gem.version.to_s] }
        .to_h
    end

    sig { params(gem_name: String, version: String).returns(Pathname) }
    def rbi_filename(gem_name, version)
      outdir / "#{gem_name}@#{version}.rbi"
    end

    sig { params(gem_name: String).returns(Pathname) }
    def existing_rbi(gem_name)
      rbi_filename(gem_name, T.must(existing_rbis[gem_name]))
    end

    sig { params(gem_name: String).returns(Pathname) }
    def expected_rbi(gem_name)
      rbi_filename(gem_name, T.must(expected_rbis[gem_name]))
    end

    sig { params(gem_name: String).returns(T::Boolean) }
    def rbi_exists?(gem_name)
      existing_rbis.key?(gem_name)
    end

    sig { returns(T::Array[String]) }
    def removed_rbis
      (existing_rbis.keys - expected_rbis.keys).sort
    end

    sig { returns(T::Array[String]) }
    def added_rbis
      expected_rbis.select do |name, value|
        existing_rbis[name] != value
      end.keys.sort
    end

    sig { params(filename: Pathname).void }
    def add(filename)
      say("++ Adding: #{filename}", :green)
      # status = execute("git add '#{filename}'")

      # unless status.success?
      #   $stderr.puts("    Failed to add RBI: #{filename}")
      #   exit(3)
      # end
    end

    sig { params(filename: Pathname).void }
    def remove(filename)
      say("-- Removing: #{filename}", :green)
      filename.unlink
      # status = execute("git rm '#{filename}'")

      # unless status.success?
      #   $stderr.puts("    Failed to remove RBI: #{filename}")
      #   exit(3)
      # end
    end

    sig { params(old_filename: Pathname, new_filename: Pathname).void }
    def move(old_filename, new_filename)
      say("-> Moving: #{old_filename} to #{new_filename}", :green)
      old_filename.rename(new_filename.to_s)
      # status = execute("git mv '#{old_filename}' '#{new_filename}'")

      # unless status.success?
      #   $stderr.puts("    Failed to move RBI: #{old_filename}")
      #   exit(3)
      # end
    end

    sig { void }
    def perform_removals
      say("Removing RBI files of gems that have been removed:", [:blue, :bold])
      puts

      anything_done = false

      gems = removed_rbis

      indent do
        if gems.empty?
          say("Nothing to do.")
        else
          gems.each do |removed|
            filename = existing_rbi(removed)
            remove(filename)
          end

          anything_done = true
        end
      end

      puts

      anything_done
    end

    sig { void }
    def perform_additions
      say("Generating RBI files of gems that are added or updated:", [:blue, :bold])
      puts

      anything_done = false

      gems = added_rbis

      indent do
        if gems.empty?
          say("Nothing to do.")
        else
          require_gem_file

          gems.each do |gem_name|
            filename = expected_rbi(gem_name)

            if rbi_exists?(gem_name)
              old_filename = existing_rbi(gem_name)
              move(old_filename, filename) unless old_filename == filename
            end

            gem = T.must(bundle.gem(gem_name))
            compile_rbi(gem)
            add(filename)

            puts
          end
        end

        anything_done = true
      end

      puts

      anything_done
    end

    sig do
      params(gem_names: T::Array[String])
        .returns(T::Array[Gemfile::Gem])
    end
    def gems_to_generate(gem_names)
      return bundle.dependencies if gem_names.empty?

      gem_names.map do |gem_name|
        gem = bundle.gem(gem_name)
        raise GemNameError.new("cannot find gem", gem_name) if gem.nil?
        gem
      end
    end

    sig { params(gem: Gemfile::Gem).void }
    def compile_rbi(gem)
      compiler = Compilers::SymbolTableCompiler.new
      say("Compiling #{gem.name}, this may take a few seconds...")

      content = compiler.compile(gem)

      FileUtils.mkdir_p(outdir)
      filename = outdir / gem.rbi_file_name
      File.write(filename.to_s, content)

      say("Compiled #{filename}")
    end
  end
end