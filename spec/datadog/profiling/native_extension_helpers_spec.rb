# typed: false
require 'ext/ddtrace_profiling_native_extension/native_extension_helpers'
require 'libddprof'

RSpec.describe Datadog::Profiling::NativeExtensionHelpers::Supported do
  describe '.supported?' do
    subject(:supported?) { described_class.supported? }

    context 'when there is an unsupported_reason' do
      before { allow(described_class).to receive(:unsupported_reason).and_return('Unsupported, sorry :(') }

      it { is_expected.to be false }
    end

    context 'when there is no unsupported_reason' do
      before { allow(described_class).to receive(:unsupported_reason).and_return(nil) }

      it { is_expected.to be true }
    end
  end

  describe '.unsupported_reason' do
    subject(:unsupported_reason) { described_class.unsupported_reason }

    before do
      allow(RbConfig::CONFIG).to receive(:[]).and_call_original
    end

    context 'when disabled via the DD_PROFILING_NO_EXTENSION environment variable' do
      around { |example| ClimateControl.modify('DD_PROFILING_NO_EXTENSION' => 'true') { example.run } }

      it { is_expected.to include 'DD_PROFILING_NO_EXTENSION' }
    end

    context 'when JRuby is used' do
      before { stub_const('RUBY_ENGINE', 'jruby') }

      it { is_expected.to include 'JRuby' }
    end

    context 'when TruffleRuby is used' do
      before { stub_const('RUBY_ENGINE', 'truffleruby') }

      it { is_expected.to include 'TruffleRuby' }
    end

    context 'when not on JRuby or TruffleRuby' do
      before { stub_const('RUBY_ENGINE', 'ruby') }

      context 'when on Windows' do
        before { expect(Gem).to receive(:win_platform?).and_return(true) }

        it { is_expected.to include 'Windows' }
      end

      context 'when not on Windows' do
        before { expect(Gem).to receive(:win_platform?).and_return(false) }

        shared_examples 'libddprof usable' do
          context 'when libddprof is not available' do
            before do
              allow(described_class)
                .to receive(:require).with('libddprof').and_raise(LoadError.new('Testing failed require'))
            end

            it { is_expected.to include '`libddprof` gem is not available' }
          end

          context 'when libddprof is available' do
            context 'but DOES NOT have binaries' do
              before { expect(Libddprof).to receive(:binaries?).and_return(false) }

              it { is_expected.to include 'gem installed on your system is missing platform-specific' }
            end

            context 'and DOES have binaries' do
              before { expect(Libddprof).to receive(:binaries?).and_return(true) }

              context 'but DOES NOT HAVE binaries for the current platform' do
                before do
                  expect(Libddprof).to receive(:pkgconfig_folder).and_return(nil)
                  expect(Libddprof).to receive(:available_binaries).and_return(['fooarch-linux', 'bararch-linux-musl'])
                end

                it { is_expected.to include 'platform variant' }
              end

              context 'and HAS BINARIES for the current platform' do
                before { expect(Libddprof).to receive(:pkgconfig_folder).and_return('/simulated/pkgconfig_folder') }

                it { is_expected.to be nil }
              end
            end
          end
        end

        context 'when Ruby CAN NOT use the MJIT header' do
          before { stub_const('Datadog::Profiling::NativeExtensionHelpers::CAN_USE_MJIT_HEADER', false) }

          include_examples 'libddprof usable'
        end

        context 'when Ruby CAN use the MJIT header' do
          before { stub_const('Datadog::Profiling::NativeExtensionHelpers::CAN_USE_MJIT_HEADER', true) }

          context 'but DOES NOT have MJIT support' do
            before { expect(RbConfig::CONFIG).to receive(:[]).with('MJIT_SUPPORT').and_return('no') }

            it { is_expected.to include 'without JIT' }
          end

          context 'and DOES have MJIT support' do
            before { expect(RbConfig::CONFIG).to receive(:[]).with('MJIT_SUPPORT').and_return('yes') }

            include_examples 'libddprof usable'
          end
        end
      end
    end
  end
end
