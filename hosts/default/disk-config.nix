{ config, lib, ... }:

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        # Disk will be detected automatically or can be specified
        # device = "/dev/sda";  # Uncomment and adjust if needed
        content = {
          type = "gpt";
          partitions = {
            # EFI partition
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };

            # Root partition
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
