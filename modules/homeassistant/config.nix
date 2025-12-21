# Home Assistant VM configuration constants
# Shared configuration values used across all Home Assistant modules
{pkgs, ...}: let
  inherit (pkgs.stdenv.hostPlatform) isAarch64;
in {
  # HAOS version and download settings
  haosVersion = "16.3";
  haosArch =
    if isAarch64
    then "generic-aarch64"
    else "ova";
  haosExt = "qcow2";
  haosFormat = "qcow2";
  haosUrl = "https://github.com/home-assistant/operating-system/releases/download/16.3/haos_${
    if isAarch64
    then "generic-aarch64"
    else "ova"
  }-16.3.qcow2.xz";
  haosImagePath = "/var/lib/kaliun/home-assistant.qcow2";

  # Architecture-specific QEMU settings
  qemuBinary = "qemu-system-${
    if isAarch64
    then "aarch64"
    else "x86_64"
  }";

  machineType =
    if isAarch64
    then "virt"
    else "q35";

  inherit isAarch64;

  # UEFI firmware paths based on architecture
  uefiCodePath =
    if isAarch64
    then
      pkgs.runCommand "padded-qemu-efi" {} ''
        mkdir -p $out
        cat ${pkgs.OVMF.fd}/FV/QEMU_EFI.fd > $out/QEMU_EFI.fd
        ${pkgs.coreutils}/bin/truncate -s 64M $out/QEMU_EFI.fd
      ''
      + "/QEMU_EFI.fd"
    else "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";

  uefiVarsPath =
    if isAarch64
    then
      pkgs.runCommand "padded-qemu-vars" {} ''
        mkdir -p $out
        cat ${pkgs.OVMF.fd}/FV/QEMU_VARS.fd > $out/QEMU_VARS.fd
        ${pkgs.coreutils}/bin/truncate -s 64M $out/QEMU_VARS.fd
      ''
      + "/QEMU_VARS.fd"
    else "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
}
