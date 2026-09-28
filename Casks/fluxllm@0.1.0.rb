cask "fluxllm@0.1.0" do
  version "0.1.0"
  sha256 "4b1d1b9c166f58c10f243a824c57acb5feaa590851edc417e3657f5def7105f4"

  url "https://github.com/chmorgan/fluxllm/releases/download/0.1.0/FluxLLM-0.1.0.zip"
  name "FluxLLM"
  desc "Menu bar monitor and proxy for local language models"
  homepage "https://github.com/chmorgan/fluxllm"

  livecheck do
    skip "This cask installs a fixed release"
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "FluxLLM.app"

  caveats <<~EOS
    Install only one FluxLLM cask at a time. Uninstall the current cask before switching versions.
  EOS
end
