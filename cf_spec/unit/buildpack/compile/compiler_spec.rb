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
require 'tmpdir'
require 'fileutils'

describe AspNetCoreBuildpack::Compiler do
  let(:installer) { double(:installer, descendants: [libunwind_installer]) }
  let(:libunwind_installer) do
    double(:libunwind_installer, install_order: 0, install: nil).tap do |libunwind_installer|
      allow(libunwind_installer).to receive(:install_description)
      allow(libunwind_installer).to receive(:cache_dir).and_return('libunwind')
      allow(libunwind_installer).to receive(:should_install).and_return(true)
      allow(libunwind_installer).to receive(:name).and_return('libunwind')
      allow(libunwind_installer).to receive(:in_runtime?).and_return(true)
      allow(libunwind_installer).to receive(:path_in_staging).and_return(nil)
    end
  end
  let(:copier) { double(:copier, cp: nil) }
  let(:build_dir) { Dir.mktmpdir }
  let(:cache_dir) { Dir.mktmpdir }

  let(:out) do
    double(:out, step: double(:unknown_step, succeed: nil, print: nil)).tap do |out|
      allow(out).to receive(:warn)
      allow(out).to receive(:print)
    end
  end

  subject(:compiler) do
    described_class.new(build_dir, cache_dir, copier, installer.descendants, out)
  end

  before do
    allow($stdout).to receive(:write)
  end

  after do
    FileUtils.rm_rf(build_dir)
    FileUtils.rm_rf(cache_dir)
  end

  shared_examples 'step' do |expected_message, step|
    let(:step_out) do
      double(:step_out, succeed: nil).tap do |step_out|
        allow(out).to receive(:step).with(expected_message).and_return step_out
      end
    end

    it 'outputs step name' do
      expect(out).to receive(:step).with(expected_message)
      allow(libunwind_installer).to receive(:cached?)
      subject.compile
    end

    it 'runs step' do
      expect(step_out).to receive(:succeed)
      allow(libunwind_installer).to receive(:cached?)
      subject.compile
    end

    context 'step fails' do
      it 'prints helpful error' do
        allow(subject).to receive(step).and_raise 'fishfinger in the warp core'
        allow(out).to receive(:fail)
        allow(step_out).to receive(:fail)
        allow(out).to receive(:warn)
        expect(step_out).to receive(:fail).with(match(/fishfinger in the warp core/))
        expect(out).to receive(:fail).with(match(/#{expected_message} failed, fishfinger in the warp core/))
        expect { subject.compile }.not_to raise_error
      end
    end
  end

  describe '#run_installers' do
    context 'Installer should not be run' do
      it 'does not run the installer' do
        allow(libunwind_installer).to receive(:should_install).and_return(false)
        expect(libunwind_installer).not_to receive(:install)
        subject.compile
      end
    end

    context 'Installer should be run' do
      it 'runs the installer' do
        allow(libunwind_installer).to receive(:should_install).and_return(true)
        expect(libunwind_installer).to receive(:install)
        subject.compile
      end
    end
  end

  describe 'Steps' do
    let(:source_code_dir) { '/dir/with/source/code' }

    before do
      allow(subject).to receive(:should_clear_nuget_cache?).and_return(true)
      allow(subject).to receive(:source_code_dir).and_return(source_code_dir)
    end

    describe 'Restoring Cache' do
      it_behaves_like 'step', 'Restoring files from buildpack cache', :restore_cache

      context 'cache does not exist' do
        it 'skips restore' do
          expect(copier).not_to receive(:cp).with(match(cache_dir), anything, anything)
          subject.compile
        end
      end

      context 'cache exists' do
        before(:each) do
          Dir.mkdir(File.join(cache_dir, 'libunwind'))
        end

        it 'copies files from cache to build dir' do
          expect(copier).to receive(:cp).with(File.join(cache_dir, 'libunwind'), build_dir, anything)
          allow(libunwind_installer).to receive(:cached?).and_return(true)
          subject.compile
        end
      end
    end

    describe 'Clearing NuGet cache' do
      it_behaves_like 'step', 'Clearing NuGet packages cache', :clear_nuget_cache

      context 'cache exists' do
        before(:each) do
          Dir.mkdir(File.join(cache_dir, '.nuget'))
          File.open(File.join(cache_dir, '.nuget', 'Package.dll'), 'w') { |f| f.write 'test' }
        end

        it 'removes the NuGet cache folder' do
          expect(File.exist?(File.join(cache_dir, '.nuget', 'Package.dll'))).to be_truthy
          subject.compile
          expect(File.exist?(File.join(cache_dir, '.nuget', 'Package.dll'))).not_to be_truthy
        end
      end

      context 'cache does not exist' do
        it 'does not raise an exception' do
          expect { subject.compile }.not_to raise_error
        end
      end
    end

    describe 'Restoring NuGet packages cache' do
      it_behaves_like 'step', 'Restoring NuGet packages cache', :restore_nuget_cache

      context 'cache does not exist' do
        it 'skips restore' do
          expect(copier).not_to receive(:cp).with(match(cache_dir), anything, anything)
          subject.compile
        end
      end

      context 'cache exists and is valid' do
        before(:each) do
          Dir.mkdir(File.join(cache_dir, '.nuget'))
        end

        it 'copies files from cache to build dir' do
          allow(subject).to receive(:nuget_cache_is_valid?).and_return(true)
          expect(copier).to receive(:cp).with(File.join(cache_dir, '.nuget'), build_dir, anything)
          subject.compile
        end
      end

      context 'cache exists, but is not valid' do
        before(:each) do
          Dir.mkdir(File.join(cache_dir, '.nuget'))
        end

        it 'skips restoring cache' do
          allow(subject).to receive(:nuget_cache_is_valid?).and_return(false)
          expect(copier).not_to receive(:cp)
          subject.compile
        end
      end
    end

    describe 'Saving to buildpack cache' do
      it_behaves_like 'step', 'Saving to buildpack cache', :save_cache

      let(:source_code_dir) { build_dir }

      before(:each) do
        Dir.mkdir(File.join(build_dir, 'libunwind'))
      end

      it 'copies files to cache dir' do
        allow(libunwind_installer).to receive(:cached?).and_return(false)
        expect(copier).to receive(:cp).with("#{build_dir}/libunwind", cache_dir, anything)
        subject.send(:save_cache, out)
      end

      context 'when the cache already exists' do
        before(:each) do
          Dir.mkdir(File.join(cache_dir, 'libunwind'))
          Dir.mkdir(File.join(source_code_dir, '.nuget'))
        end

        it 'copies only .nuget to cache dir' do
          allow(libunwind_installer).to receive(:cached?).and_return(true)
          expect(copier).to receive(:cp).with("#{source_code_dir}/.nuget", cache_dir, anything)
          subject.send(:save_cache, out)
        end
      end

      context 'when the files fail to copy to the cache' do
        before(:each) do
          Dir.mkdir(File.join(cache_dir, 'libunwind'))
        end

        it 'does not throw an exception' do
          allow(copier).to receive(:cp).and_raise(StandardError)
          expect(out).to receive(:fail).with(anything)
          expect { subject.send(:save_cache, out) }.not_to raise_error
        end

        it 'outputs a failure message' do
          allow(copier).to receive(:cp).and_raise(StandardError)
          expect(out).to receive(:fail).with('Failed to save cached files for libunwind')
          subject.send(:save_cache, out)
        end

        it 'removes the cache folder' do
          allow(copier).to receive(:cp).and_raise(StandardError)
          expect(out).to receive(:fail).with('Failed to save cached files for libunwind')
          subject.send(:save_cache, out)
          expect(File.exist?(File.join(cache_dir, 'libunwind'))).not_to be_truthy
        end
      end
    end
  end

  describe '#should_clear_nuget_cache?' do
    context 'NuGet cache exists' do
      context 'NuGet package cache is invalid' do
        before do
          allow(subject).to receive(:nuget_cache_is_valid?).and_return(false)
        end

        it 'returns true' do
          expect(subject).to receive(:should_clear_nuget_cache?).and_return(true)
          subject.compile
        end
      end

      context 'NuGet package cache is valid' do
        context 'CACHE_NUGET_PACKAGES is set to false' do
          before do
            ENV['CACHE_NUGET_PACKAGES'] = 'false'
          end

          it 'returns true' do
            expect(subject).to receive(:should_clear_nuget_cache?).and_return(true)
            subject.compile
          end
        end

        context 'CACHE_NUGET_PACKAGES is not set to false' do
          it 'returns false' do
            expect(subject).to receive(:should_clear_nuget_cache?).and_return(false)
            subject.compile
          end
        end
      end
    end

    context 'NuGet cache does not exist' do
      it 'returns false' do
        expect(subject).to receive(:should_clear_nuget_cache?).and_return(false)
        subject.compile
      end
    end
  end

  describe '#should_save_nuget_cache' do
    context '.nuget folder exists in build_dir' do
      context 'CACHE_NUGET_PACKAGES is set to false' do
        before do
          ENV['CACHE_NUGET_PACKAGES'] = 'false'
        end

        it 'returns false' do
          expect(subject).to receive(:should_save_nuget_cache?).and_return(false)
          subject.compile
        end
      end

      context 'CACHE_NUGET_PACKAGES is not set to false' do
        it 'returns true' do
          expect(subject).to receive(:should_save_nuget_cache?).and_return(false)
          subject.compile
        end
      end
    end
  end

  describe '#should_clear_nuget_cache?' do
    context 'CACHE_NUGET_PACKAGES is set to false' do
      before do
        ENV['CACHE_NUGET_PACKAGES'] = 'false'
      end

      context 'cache folder exists' do
        before do
          FileUtils.mkdir_p(File.join(cache_dir, '.nuget'))
        end

        it 'returns true' do
          expect(subject.send(:should_clear_nuget_cache?)).to be_truthy
        end
      end

      context 'cache folder does not exist' do
        it 'returns false' do
          expect(subject.send(:should_clear_nuget_cache?)).not_to be_truthy
        end
      end
    end

    context 'CACHE_NUGET_PACKAGES is not set to false' do
      it 'returns false' do
        expect(subject.send(:should_clear_nuget_cache?)).not_to be_truthy
      end
    end
  end

  describe '#move_app_source_code' do
    let(:app_file)        { 'src/project1/project.json' }
    let(:deployment_file) { '.deployment' }
    let(:dotnet_dir)      { '.dotnet' }
    let(:libunwind_dir)   { 'libunwind' }
    let(:profile_file)    { '.profile' }

    before do
      FileUtils.mkdir_p(File.join(build_dir, 'src/project1'))
      File.write(File.join(build_dir, app_file), 'xxx')
      File.write(File.join(build_dir, deployment_file), 'xxx')
      File.write(File.join(build_dir, profile_file), 'xxx')

      FileUtils.mkdir_p(File.join(build_dir, libunwind_dir))
      FileUtils.mkdir_p(File.join(build_dir, dotnet_dir))
    end

    after do
      FileUtils.rm_rf(@dest_dir)
    end

    it 'moves the app files to a temp directory' do
      @dest_dir = subject.send(:move_app_source_code, out)
      expect(File.exist? File.join(build_dir, app_file)).not_to be_truthy
      expect(File.exist? File.join(@dest_dir, app_file)).to be_truthy
    end

    it 'moves the .deployment file to a temp directory' do
      @dest_dir = subject.send(:move_app_source_code, out)
      expect(File.exist? File.join(build_dir, deployment_file)).not_to be_truthy
      expect(File.exist? File.join(@dest_dir, deployment_file)).to be_truthy
    end

    it 'does not move the .dotnet directory' do
      @dest_dir = subject.send(:move_app_source_code, out)
      expect(File.exist? File.join(@dest_dir, dotnet_dir)).not_to be_truthy
      expect(File.exist? File.join(build_dir, dotnet_dir)).to be_truthy
    end

    it 'does not move the .profile file' do
      @dest_dir = subject.send(:move_app_source_code, out)
      expect(File.exist? File.join(@dest_dir, profile_file)).not_to be_truthy
      expect(File.exist? File.join(build_dir, profile_file)).to be_truthy
    end

    it 'does not move the libunwind directory' do
      @dest_dir = subject.send(:move_app_source_code, out)
      expect(File.exist? File.join(@dest_dir, libunwind_dir)).not_to be_truthy
      expect(File.exist? File.join(build_dir, libunwind_dir)).to be_truthy
    end
  end

  describe '#compile_dotnet_app' do
    let(:shell) { double(:shell) }

    before do
      allow(subject).to receive(:shell).and_return(shell)
    end

    after do
      FileUtils.rm_rf(subject.source_code_dir)
    end

    context 'the app has multiple project.json files' do
      let(:project1_file)        { 'src/project1/project.json' }
      let(:project2_file)        { 'src/project2/project.json' }
      let(:deployment_file) { '.deployment' }
      let(:deployment_contents) do
        <<-HEREDOC
[config]
project=src/project2
        HEREDOC
      end
      before do
        FileUtils.mkdir_p(File.join(build_dir, 'src/project1'))
        FileUtils.mkdir_p(File.join(build_dir, 'src/project2'))
        File.write(File.join(build_dir, project1_file), 'xxx')
        File.write(File.join(build_dir, project2_file), 'xxx')
        File.write(File.join(build_dir, deployment_file), deployment_contents)
      end

      it 'runs dotnet restore for each project and dotnet publish for the main project' do
        expect(shell).to receive(:exec) do |*args|
          cmd = args.first
          expect(cmd).to match(/dotnet restore/)
          expect(cmd).to match(%r{src/project1 src/project2})
        end

        expect(shell).to receive(:exec) do |*args|
          cmd = args.first
          expect(cmd).to match(/dotnet publish/)
          expect(cmd).to match(%r{src/project2})
          expect(cmd).not_to match(%r{src/project1})
        end

        subject.send(:compile_dotnet_app, out)
      end
    end

    context 'the app has one project.json file' do
      let(:project_file) { 'src/project1/project.json' }

      before do
        FileUtils.mkdir_p(File.join(build_dir, 'src/project1'))
        File.write(File.join(build_dir, project_file), 'xxx')
      end

      it 'runs dotnet restore and dotnet publish for the correct project' do
        expect(shell).to receive(:exec) do |*args|
          cmd = args.first
          expect(cmd).to match(/dotnet restore/)
          expect(cmd).to match(%r{src/project1})
        end

        expect(shell).to receive(:exec) do |*args|
          cmd = args.first
          expect(cmd).to match(/dotnet publish/)
          expect(cmd).to match(%r{src/project1})
        end

        subject.send(:compile_dotnet_app, out)
      end
    end
  end

  describe '#compilation_environment' do
    let(:source_code_dir)     { Dir.mktmpdir }
    let(:app_dir)             { AspNetCoreBuildpack::AppDir.new(source_code_dir) }
    let(:build_dir)           { '/tmp/app' }
    let(:environment)         { subject.send(:compilation_environment) }
    let(:installer)           { double(:installer, descendants: [libunwind_installer, nodejs_installer, dotnet_installer]) }
    let(:libunwind_installer) { double(:libunwind_installer, path_in_staging: nil) }
    let(:nodejs_installer)    { double(:nodejs_installer, path_in_staging: '$HOME/.node/node-v6.7.0-linux-x64/bin') }
    let(:dotnet_installer)    { double(:dotnet_installer, path_in_staging: File.join(build_dir, '.dotnet')) }
    let(:project1_dir)        { File.join(source_code_dir, 'src', 'project1') }
    let(:project2_dir)        { File.join(source_code_dir, 'src', 'project2') }

    before do
      FileUtils.mkdir_p([project1_dir, project2_dir])
      File.write(File.join(project1_dir, 'project.json'), 'xxx')
      File.write(File.join(project2_dir, 'project.json'), 'xxx')

      allow(subject).to receive(:app_dir).and_return(app_dir)
      allow(subject).to receive(:source_code_dir).and_return(source_code_dir)
    end

    it 'sets HOME as the directory with the moved source code' do
      expect(environment['HOME']).to eq(source_code_dir)
    end

    it 'sets LD_LIBRARY_PATH to include the directory with libunwind' do
      expect(environment['LD_LIBRARY_PATH']).to eq('$LD_LIBRARY_PATH:/tmp/app/libunwind/lib')
    end

    it 'sets PATH to include the directory with dotnet CLI, node, and node module binaries' do
      paths = environment['PATH'].split(':')
      expect(paths).to include('$PATH')
      expect(paths).to include('/tmp/app/.dotnet')
      expect(paths).to include('$HOME/.node/node-v6.7.0-linux-x64/bin')
      expect(paths).to include(File.join(source_code_dir, 'src/project1/node_modules/.bin'))
      expect(paths).to include(File.join(source_code_dir, 'src/project2/node_modules/.bin'))
    end
  end
end
