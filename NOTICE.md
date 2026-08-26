# Notice

## Primary references

The following primary service and vendor references were checked on 2026-08-26:

- [JPIX v6 Plus static IP service](https://www.jpix.ad.jp/service/?p=3447)
- [JPIX public v6 Plus device development guide, revision 1.3](https://www.jpix.ad.jp/files/developer_guide_v6plus_v1.3.pdf)
- [JPIX public device development guide, revision 1.2](https://www.jpix.ad.jp/files/developer_guide_v6plus-static_v1.2.pdf)
- [JPIX v6 Plus compatible models](https://www.jpix.ad.jp/service/?p=3565)
- [JPIX v6 Plus static IP configuration examples](https://www.jpix.ad.jp/service/?p=3458)
- [Yamaha v6 Plus technical documentation](https://www.rtpro.yamaha.co.jp/RT/docs/v6plus/)
- [Yamaha HB46PP technical documentation](https://www.rtpro.yamaha.co.jp/RT/docs/hb46pp/)
- [JAIPA HB46PP specification, revision 1.2](https://github.com/v6pc/v6mig-prov/blob/master/spec.md)
- [JPNE/JPIX IPv4/IPv6 connection diagnostic page, legacy URL](http://wa.kiriwake.jpne.co.jp/)
- [IPv4/IPv6 connection diagnostic page, HTTPS](https://kiriwake.jpne.co.jp/)
- [en Hikari v6 Plus service information](https://enhikari.jp/v6plus.html)
- [Ubiquiti IPv6 configuration guide](https://help.ui.com/hc/en-us/articles/36378535649687-Configuring-IPv6-in-UniFi)

## Interpretation

JPIX describes ordinary v6 Plus as IPv6 IPoE plus MAP-E, with a map-rule distribution server and MAP-BR. JPIX describes the static-IP service separately as dual-stack IPv6 IPoE plus IPv4-in-IPv6 to a fixed-IP BR. The static-IP service offers multiple IPv4 address plans, but this repository implements only one static IPv4 address as a tunnel `/32` with SNAT.

HB46PP is a provisioning protocol that can distribute parameters for several IPv4-over-IPv6 mechanisms. Similarity at the IPIP data plane does not make JPIX static-IP endpoint notification an HB46PP implementation. This repository performs neither HB46PP DNS discovery nor provisioning-response processing.

As of the check date, UDM Pro and Ubiquiti were not listed on the JPIX compatible-model page. The en Hikari page is retained as provider service context and is not evidence of UDM Pro fixed-IP support. Yamaha documentation is a vendor implementation reference and must not be copied as a UniFi configuration.

The Ubiquiti guide documents native IPv6 configuration concepts. It does not document or endorse this JPIX fixed-IP tunnel repair.

The connection diagnostic page reports browser-observed source addresses, source ports, reachability tests, and a service classification. It is external connectivity evidence, not evidence that this repository's internal tunnel state or recovery automation is correct. Its result must be redacted before public sharing.

## Project status

This repository is an independent, unsupported integration. Live preflight on UDM Pro and UniFi OS 5 confirmed native IPv6, a UniFi-managed IPIP6 tunnel candidate, UniFi user chains, and DHCPv6-PD processing. A 2026-08-26 external service check identified the live connection as v6 Plus static IP and passed IPv4 and IPv6 connectivity checks. Project-controlled dry-run, apply, prefix-change recovery, reboot recovery, and rollback remain subject to live validation.

No provider credentials or assigned deployment addresses are included in this repository.
