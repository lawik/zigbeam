defmodule Zigbeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :zigbeam,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      atomvm: [
        start: Zigbeam,
        # XIAO ESP32-C6 shows up as the Espressif USB JTAG/serial device.
        chip: "esp32c6",
        port: "/dev/ttyACM1",
        baud: "921600"
      ]
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp deps do
    [
      {:exatomvm, git: "https://github.com/atomvm/exatomvm/", runtime: false},
      {:atomvm, "~> 0.7.0-beta.0", runtime: false},
      {:pythonx, "~> 0.4.0", runtime: false},
      {:req, "~> 0.7.0", runtime: false}
    ]
  end
end
