# AdGuard Home

The installer:
- installs `adguardhome` and stores its data on disk at `/opt/adguardhome`, so stats survive reboots
- moves dnsmasq to **port 54**, where it keeps doing DHCP and local hostnames
- tells DHCP clients to use the router (`LAN_IP`) for DNS

**Until you finish the wizard, AdGuard doesn't answer DNS, and your devices can't resolve names.** Do it right after the first reboot. If you get stuck: `sh tools/adguard-rollback.sh`.

## Wizard (`http://<LAN_IP>:3000`)

| Step | Setting |
|---|---|
| Admin web interface | **All interfaces**, port **3000**. Don't use 80, that's LuCI. If 3000 says "address already in use", pick All interfaces or use 8080. |
| DNS server | **All interfaces**, port **53** |
| Account | your own username and password |

## Recommended settings (Settings → DNS settings)

**Upstream DNS servers**

```
https://dns.cloudflare.com/dns-query
https://dns.google/dns-query
[/lan/]127.0.0.1:54
```

Select **Parallel requests**. The last line sends local names (`pc.lan`) to dnsmasq.

**Bootstrap DNS**: `1.1.1.1` and `8.8.8.8`

**Private reverse DNS servers**: `127.0.0.1:54`. Enable both *Use private reverse DNS resolvers* and *Enable reverse resolving of clients' IP addresses*, so the logs show device names.

**Rate limit**: `0`. The default 20/s can throttle a console or PC downloading an update.

**Cache**: size `67108864` (64 MB), **Optimistic caching on**.

## Blocklists (Filters → DNS blocklists)

- AdGuard DNS filter (on by default)
- **HaGeZi's Normal Blocklist**

Avoid Pro++ / Ultimate and stacking many lists. Those are what break game logins, matchmaking and anti-cheat. If a game won't connect, check **Query Log** for blocked domains and allow them.

## Does it affect ping?

No. DNS only runs when a game looks up a server name. In-match packets go straight to the server's IP. Local caching actually makes lookups faster.
