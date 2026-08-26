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
- [Cisco SD-WAN IPoE JPIX configuration](https://community.cisco.com/t5/tkb-%E3%83%8D%E3%83%83%E3%83%88%E3%83%AF%E3%83%BC%E3%82%AD%E3%83%B3%E3%82%B0-%E3%83%89%E3%82%AD%E3%83%A5%E3%83%A1%E3%83%B3%E3%83%88/cisco-sd-wan-ipoe-jpix%E7%B7%A8/ta-p/4597068)
- [Alpha Web v6 Plus static-IP IX2106 configuration guide](https://www.alpha-web.ne.jp/help/v6plus/Web_v6Plus-IP1-IX2106.html)
- [Alpha Web reconfiguration URL FAQ](https://www.alpha-web.ne.jp/faq/v6plus/020431.html)
- [JPNE/JPIX IPv4/IPv6 connection diagnostic page, legacy URL](http://wa.kiriwake.jpne.co.jp/)
- [IPv4/IPv6 connection diagnostic page, HTTPS](https://kiriwake.jpne.co.jp/)
- [en Hikari v6 Plus service information](https://enhikari.jp/v6plus.html)
- [Ubiquiti IPv6 configuration guide](https://help.ui.com/hc/en-us/articles/36378535649687-Configuring-IPv6-in-UniFi)

## Supplemental implementation records

The following field reports were checked for operational observations and conflicting UI terminology. They are not service specifications:

- [NET INNOVATION: terminating v6 Plus static IP on UniFi](https://www.net-innovation.jp/blog/unifi-v6plus-static-ip)
- [RamuneMemo: configuring RTX830 for static-IP v6 Plus](https://ramunememo.hatenablog.com/entry/2022/06/20/004145)
- [Zenn: activating static IPv4 on FLET'S Hikari Cross with RTX1300](https://zenn.dev/playree/articles/28e652469c1102)

## Interpretation

JPIX describes ordinary v6 Plus as IPv6 IPoE plus MAP-E, with a map-rule distribution server and MAP-BR. JPIX describes the static-IP service separately as dual-stack IPv6 IPoE plus IPv4-in-IPv6 to a fixed-IP BR. The static-IP service offers multiple IPv4 address plans, but this repository implements only one static IPv4 address as a tunnel `/32` with SNAT.

HB46PP is a provisioning protocol that can distribute parameters for several IPv4-over-IPv6 mechanisms. Similarity at the IPIP data plane does not make JPIX static-IP endpoint notification an HB46PP implementation. This repository performs neither HB46PP DNS discovery nor provisioning-response processing.

As of the check date, UDM Pro and Ubiquiti were not listed on the JPIX compatible-model page. The en Hikari page is retained as provider service context and is not evidence of UDM Pro fixed-IP support. Yamaha documentation is a vendor implementation reference and must not be copied as a UniFi configuration.

The Ubiquiti guide documents native IPv6 configuration concepts. It does not document or endorse this JPIX fixed-IP tunnel repair.

Alpha Web and Cisco publish `http://fcs.enabler.ne.jp/update` as the router-facing update or reconfiguration endpoint. One supplemental RTX1300 report shows the host root instead, while another RTX830 report records HTML being returned when `/update` is omitted. This repository therefore documents the complete `/update` path and defers to the subscriber's current ISP-issued registration notice when it differs. The endpoint is HTTP in the public examples, so update credentials are not transport-encrypted; the implementation requires an explicit exact-host opt-in for HTTP.

The connection diagnostic page reports browser-observed source addresses, source ports, reachability tests, and a service classification. It is external connectivity evidence, not evidence that this repository's internal tunnel state or recovery automation is correct. Its result must be redacted before public sharing.

## Project status

This repository is an independent, unsupported integration. Live validation on one UDM Pro and UniFi OS 5 tuple confirmed native IPv6, DHCPv6-PD LAN `/64` evidence, a UniFi-managed IPIP6 tunnel, validated UniFi user hooks, project-controlled dry-run and apply, target-LAN IPv4/IPv6/DNS, provider notification, timed recovery, rollback, reapply, and reboot recovery. The new trigger, watch, and update timer were enabled and remained active after reboot; a short status soak and the first scheduled provider update succeeded. Public provider documentation and live reachability checks did not establish a supported HTTPS update endpoint, so the documented HTTP endpoint remains in use rather than guessing an HTTPS URL. Reprovision, prefix-change recovery, standalone-tunnel comparison, PMTUD, non-target-LAN client validation, and post-change browser validation remain open in Issues #3 through #7.

No provider credentials or assigned deployment addresses are included in this repository.
