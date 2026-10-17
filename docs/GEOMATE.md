# Geomate: Call of Duty geo-filter

[Geomate](https://github.com/hudra0/geomate) lets you draw circles on a map and only allow game server connections inside them. It learns server IPs as you play.

The installer creates a `Call of Duty` filter:
- protocol UDP, source port `3074`, source IP = first entry in `GAMING_IPS`
- IP list `/etc/geomate.d/cod_servers.txt` (bundled, geolocated in the background)
- allowed IPs `185.34.107.128` and `185.34.107.129` (matchmaking/auth, per the geomate docs)
- **monitor mode**: logs and maps connections but blocks nothing

## Finish setup

1. **Services → Geomate → View**: draw a circle with the circle tool over where you want to play.
2. Name it **exactly `Call of Duty`** so it attaches to the existing filter. Save, then Save & Apply.
3. **Play several matches in monitor mode.** The map fills in with the servers you actually hit.
4. Switch **Operational mode** to **Dynamic**. Servers outside your circle are now blocked, and new ones keep being learned.
5. Leave **Strict mode off** until the list is well built. Strict blocks any server not yet geolocated.

## Tips

- **Confirm your port.** Start a match, open Network → QoSmate → Connections, filter by your PC's IP, and sort by packets per second. The steady UDP flow is the game. Use whichever port stays constant (source 3074 for CoD).
- **Matchmaking slow?** Widen the circle. Fewer servers means longer searches.
- **Daily geolocation** (the default here) avoids a server getting blocked mid-match after it's newly located.
- Need more always-allowed servers? Add them under the filter's *Allowed IPs* and don't add everything, or you defeat the filter.
- Geomate does **not** lower your ping to a given server. It keeps you off far-away ones.
