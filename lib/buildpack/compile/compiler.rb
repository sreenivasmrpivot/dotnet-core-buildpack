# Encoding: utf-8
# ASP.NET Core Buildpack
# Copyright 2014-2016 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative '../bp_version.rb'
require_relative './installers/installer.rb'
require_relative './installers/libunwind_installer.rb'
require_relative './installers/dotnet_installer.rb'
require_relative './installers/nodejs_installer.rb'
require_relative './installers/bower_installer.rb'

require 'json'
require 'pathname'

module AspNetCoreBuildpack
  class Compiler
    attr_reader :source_code_dir

    CACHE_NUGET_PACKAGES_VAR = 'CACHE_NUGET_PACKAGES'.freeze
    NUGET_CACHE_DIR = '.nuget'.freeze

    def initialize(build_dir, cache_dir, copier, installers, out)
      @build_dir = build_dir
      @source_code_dir = build_dir
      @cache_dir = cache_dir
      @copier = copier
      @out = out
      @app_dir = AppDir.new(@build_dir)
      @shell = AspNetCoreBuildpack.shell
      @installers = installers
      @dotnet = installers.find { |installer| /(.*)::DotnetInstaller/.match(installer.class.name) }
    end

    def compile
      puts "ASP.NET Core buildpack version: #{BuildpackVersion.new.version}\n"
      puts "ASP.NET Core buildpack starting compile\n"
      step('Restoring files from buildpack cache', method(:restore_cache))
      step('Clearing NuGet packages cache', method(:clear_nuget_cache)) if should_clear_nuget_cache?
      step('Restoring NuGet packages cache', method(:restore_nuget_cache))
      run_installers
      if dotnet_should_compile
        step('Compiling application with Dotnet CLI', method(:compile_dotnet_app))
      end
      step('Saving to buildpack cache', method(:save_cache))
      puts "ASP.NET Core buildpack is done creating the droplet\n"
      return true
    rescue StepFailedError => e
      out.fail(e.message)
      return false
    end

    private

    def clear_nuget_cache(_out)
      FileUtils.rm_rf(File.join(cache_dir, NUGET_CACHE_DIR))
    end

    def compile_dotnet_app(out)
      @source_code_dir = move_app_source_code(out)
      @app_dir = AppDir.new(@source_code_dir)

      @shell.env.merge! compilation_environment

      project_list = @app_dir.with_project_json.join(' ')

      cmd = "bash -c 'cd #{@source_code_dir}; dotnet restore --verbosity minimal #{project_list}'"
      shell.exec(cmd, out)

      main_project = @app_dir.main_project_path
      fail 'No project found to build' if main_project.nil?

      cmd = "bash -c 'cd #{@source_code_dir}; dotnet publish #{main_project} -o #{@build_dir} -c Release'"
      shell.exec(cmd, out)
    end

    def move_app_source_code(out)
      keep_in_droplet = %w(. .. .dotnet .profile libunwind)
      dest_dir = Dir.mktmpdir
      out.print "Moving application source code from #{@build_dir} to #{dest_dir}"
      files_to_move = Dir.entries(@build_dir).select do |entry|
        !keep_in_droplet.include?(entry)
      end

      Dir.chdir(@build_dir) do
        FileUtils.mv(files_to_move, dest_dir)
      end

      dest_dir
    end

    def compilation_environment
      compilation_env = {}
      compilation_env['HOME'] = source_code_dir
      compilation_env['LD_LIBRARY_PATH'] = "$LD_LIBRARY_PATH:#{@build_dir}/libunwind/lib"

      binary_paths = @installers.map(&:path_in_staging).compact.join(':')

      node_modules_paths = app_dir.with_project_json.map do |dir|
        File.join(source_code_dir, dir, 'node_modules', '.bin')
      end.compact.join(':')

      compilation_env['PATH'] = "$PATH:#{binary_paths}:#{node_modules_paths}"

      compilation_env
    end

    def dotnet_should_compile
      dotnet.should_compile(@app_dir) unless dotnet.nil?
    end

    def nuget_cache_is_valid?
      return false if @dotnet.nil? || !File.exist?(File.join(cache_dir, NUGET_CACHE_DIR))
      !@dotnet.should_install(@app_dir)
    end

    def run_installers
      @installers.each do |installer|
        step(installer.install_description, installer.method(:install)) if installer.should_install(@app_dir)
      end
    end

    def restore_cache(out)
      @installers.map(&:cache_dir).compact.each do |installer_cache_dir|
        copier.cp(File.join(cache_dir, installer_cache_dir), build_dir, out) if File.exist? File.join(cache_dir, installer_cache_dir)
      end
    end

    def restore_nuget_cache(out)
      copier.cp(File.join(cache_dir, NUGET_CACHE_DIR), build_dir, out) if nuget_cache_is_valid?
    end

    def save_cache(out)
      @installers.select { |installer| !installer.cache_dir.nil? }.compact.each do |installer|
        if installer.in_runtime?
          dir_to_copy = File.join(build_dir, installer.cache_dir)
        else
          dir_to_copy = File.join(source_code_dir, installer.cache_dir)
        end
        save_installer_cache(out, installer.name, dir_to_copy)
      end
      save_installer_cache(out, 'Nuget packages'.freeze, File.join(source_code_dir, NUGET_CACHE_DIR)) if should_save_nuget_cache?
    end

    def save_installer_cache(out, name, dir_to_copy)
      copier.cp(dir_to_copy, cache_dir, out) if File.exist? dir_to_copy
    rescue
      destination_dir = File.join(cache_dir, File.basename(dir_to_copy))

      out.fail("Failed to save cached files for #{name}")
      FileUtils.rm_rf(destination_dir) if File.exist? destination_dir
    end

    def should_clear_nuget_cache?
      File.exist?(File.join(cache_dir, NUGET_CACHE_DIR)) && (ENV[CACHE_NUGET_PACKAGES_VAR] == 'false' || !nuget_cache_is_valid?)
    end

    def should_save_nuget_cache?
      File.exist?(File.join(build_dir, NUGET_CACHE_DIR)) && ENV[CACHE_NUGET_PACKAGES_VAR] != 'false'
    end

    def step(description, method)
      s = out.step(description)
      begin
        method.call(s)
      rescue => e
        s.fail(e.message)
        raise StepFailedError, "#{description} failed, #{e.message}"
      end

      s.succeed
    end

    attr_reader :app_dir
    attr_reader :build_dir
    attr_reader :cache_dir
    attr_reader :dotnet
    attr_reader :installers
    attr_reader :copier
    attr_reader :out
    attr_reader :shell
  end

  class StepFailedError < StandardError
  end
end
