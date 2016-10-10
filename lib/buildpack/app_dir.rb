# Encoding: utf-8
# ASP.NET Core Buildpack
# Copyright 2015-2016 the original author or authors.
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

module AspNetCoreBuildpack
  class AppDir
    DEPLOYMENT_FILE_NAME = '.deployment'.freeze

    def initialize(dir)
      @dir = dir
    end

    def root
      @dir
    end

    def with_command(cmd)
      with_project_json.select { |d| !commands(d)[cmd].nil? && commands(d)[cmd] != '' }
    end

    def with_project_json
      Dir.glob(File.join(@dir, '**', 'project.json')).map do |d|
        Pathname.new(File.dirname(d)).relative_path_from(Pathname.new(@dir))
      end
    end

    def project_json(dir)
      File.join(@dir, dir, 'project.json')
    end

    def commands(dir)
      JSON.load(IO.read(project_json(dir), encoding: 'bom|utf-8')).fetch('commands', {})
    end

    def deployment_file_project
      paths = with_project_json
      deployment_file = File.expand_path(File.join(@dir, DEPLOYMENT_FILE_NAME))

      if File.exist?(deployment_file)
        File.foreach(deployment_file, encoding: 'utf-8') do |line|
          m = /project[ \t]*=[ \t]*(.*)/i.match(line)
          if m
            n = /.*([.](xproj|csproj))/i.match(m[1])
            path = n ? Pathname.new(File.dirname(m[1])) : Pathname.new(m[1])
            return path if paths.include?(path)
          end
        end
      end

      nil
    end

    def main_project_path
      deployment_path = deployment_file_project
      project_paths = with_project_json

      if deployment_path
        path = deployment_path
      elsif project_paths.one?
        path = project_paths.first
      elsif project_paths.count > 1
        fail 'Multiple paths contain a project.json file, but no .deployment file was used'
      else
        path = nil
      end

      path
    end

    def published_project
      config_files = Dir.glob(File.join(@dir, '*.runtimeconfig.json'))

      Pathname.new(config_files.first).basename.to_s.split('.').first if config_files.one?
    end
  end
end
