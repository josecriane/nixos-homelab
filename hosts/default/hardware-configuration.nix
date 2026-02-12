{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.memtest86.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Geekom A6 - AMD Ryzen 7 6800H
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "thunderbolt"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];
  boot.kernelModules = [ "kvm-amd" ];

  # AMD microcode updates
  hardware.cpu.amd.updateMicrocode = true;

  # Firmware
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # nixos-anywhere needs this to detect the disk
  # Can be adjusted after the first installation
  disko.devices.disk.main.device = "/dev/nvme0n1";
}
