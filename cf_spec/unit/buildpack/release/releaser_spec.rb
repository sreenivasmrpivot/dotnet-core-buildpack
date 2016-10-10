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

$LOAD_PATH << 'cf_spec'
require 'spec_helper'
require 'rspec'
require 'yaml'
require 'tmpdir'
require 'fileutils'

describe AspNetCoreBuildpack::Releaser do
  let(:build_dir) { Dir.mktmpdir }
  let(:cache_dir) { Dir.mktmpdir }
  let(:out) { AspNetCoreBuildpack::Out.new }
  before do
    FileUtils.mkdir_p(File.join(build_dir, AspNetCoreBuildpack::DotnetInstaller.new(build_dir, cache_dir, out).cache_dir))
  end

  describe '#release' do
    context 'project.json does not exist in source code project' do
      it 'raises an error because dotnet restore command will not work' do
        expect { subject.release(build_dir) }.to raise_error(/No project could be identified to run/)
      end
    end

    context 'project.json does not exist in published project' do
      let(:profile_d_script) do
        allow_any_instance_of(AspNetCoreBuildpack::DotnetInstaller).to receive(:cached?).and_return(true)
        allow_any_instance_of(AspNetCoreBuildpack::LibunwindInstaller).to receive(:cached?).and_return(true)
        subject.release(build_dir)
        IO.read(File.join(build_dir, '.profile.d', 'startup.sh'))
      end

      let(:web_process) do
        yml = YAML.load(subject.release(build_dir))
        yml.fetch('default_process_types').fetch('web')
      end

      before do
        File.open(File.join(build_dir, 'proj1.runtimeconfig.json'), 'w') { |f| f.write('a') }
      end

      shared_examples 'writes the correct values in the .profile.d script' do
        it 'set HOME env variable in profile.d' do
          expect(profile_d_script).to include('export HOME=/app')
        end

        it 'set LD_LIBRARY_PATH in profile.d' do
          expect(profile_d_script).to include('export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$HOME/libunwind/lib')
        end

        it 'add Dotnet CLI to the PATH in profile.d' do
          expect(profile_d_script).to include('$HOME/.dotnet')
        end

        it 'start command does not contain any exports' do
          expect(web_process).not_to include('export')
        end
      end

      context 'project is self-contained' do
        before do
          File.open(File.join(build_dir, 'proj1'), 'w') { |f| f.write('a') }
        end

        it_behaves_like 'writes the correct values in the .profile.d script'

        it 'does not raise an error because project.json is not required' do
          expect { subject.release(build_dir) }.not_to raise_error
        end

        it 'runs native binary for the project which has a runtimeconfig.json file' do
          expect(web_process).to match('proj1')
        end
      end

      context 'project is a portable project' do
        before do
          File.open(File.join(build_dir, 'proj1.dll'), 'w') { |f| f.write('a') }
        end

        it_behaves_like 'writes the correct values in the .profile.d script'

        it 'runs dotnet <dllname> for the project which has a runtimeconfig.json file' do
          expect(web_process).to match('dotnet proj1.dll')
        end
      end
    end
  end
end
