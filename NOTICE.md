# Notice

## Primary references

The following primary service and vendor references were checked on 2026-08-26:

- [JPIX v6 Plus static IP service](https://www.jpix.ad.jp/service/?p=3447)
- [JPIX public device development guide, revision 1.2](https://www.jpix.ad.jp/files/developer_guide_v6plus-static_v1.2.pdf)
- [JPIX v6 Plus compatible models](https://www.jpix.ad.jp/service/?p=3565)
- [JPIX v6 Plus static IP configuration examples](https://www.jpix.ad.jp/service/?p=3458)
- [Yamaha v6 Plus technical documentation](https://www.rtpro.yamaha.co.jp/RT/docs/v6plus/)
- [en Hikari v6 Plus service information](https://enhikari.jp/v6plus.html)
- [Ubiquiti IPv6 configuration guide](https://help.ui.com/hc/en-us/articles/36378535649687-Configuring-IPv6-in-UniFi)

## Interpretation

JPIX describes the static-IP service as dual-stack IPv6 IPoE plus IPv4 connectivity over IPv6. Its public development guide revision 1.2 identifies IPv4-in-IPv6 and DHCPv6-PD as relevant protocol elements. These references describe the service, not support for this repository or UDM Pro.

As of the check date, UDM Pro and Ubiquiti were not listed on the JPIX compatible-model page. The en Hikari page is retained as provider service context and is not evidence of UDM Pro fixed-IP support. Yamaha documentation is a vendor implementation reference and must not be copied as a UniFi configuration.

The Ubiquiti guide documents native IPv6 configuration concepts. It does not document or endorse this JPIX fixed-IP tunnel repair.

## Project status

This repository is an independent, unsupported integration. Live preflight on UDM Pro and UniFi OS 5 confirmed native IPv6, a UniFi-managed IPIP6 tunnel candidate, UniFi user chains, and DHCPv6-PD processing. Dry-run, fixed IPv4 traffic, reboot recovery, and rollback remain subject to live validation.

No provider credentials or assigned deployment addresses are included in this repository.
