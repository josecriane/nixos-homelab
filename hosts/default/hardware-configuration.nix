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

  # Common kernel modules
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-amd" ]; # AMD Ryzen 5800U

  # Blacklist problematic AMD modules
  boot.blacklistedKernelModules = [
    "pcie_mp2_amd" # AMD Sensor Fusion Hub - causes errors
    "amd_sfh" # AMD Sensor Fusion Hub driver
  ];

  # AMD Ryzen 5800U workarounds:
  # - processor.max_cstate=1: prevent deep C-state sleep (C6 causes hard lockups on cpu cores)
  # - spec_rstack_overflow=microcode: SRSO mitigation via microcode instead of kernel thunks
  boot.kernelParams = [
    "processor.max_cstate=1"
    "spec_rstack_overflow=microcode"
  ];

  # AMD microcode updates
  hardware.cpu.amd.updateMicrocode = true;

  # Firmware
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # nixos-anywhere needs this to detect the disk
  # Can be adjusted after the first installation
  disko.devices.disk.main.device = lib.mkDefault "/dev/sda";
}
