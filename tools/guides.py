#!/usr/bin/env python3
"""Keep the guide lists on vpnonly.app in step with the guides themselves.

    python3 tools/guides.py

The homepage shows six guides: the newest one first, then the PINNED ones.
The guides page lists every guide, newest first, with its icon and the day it
went up. Both lists, and the sitemap, come from GUIDES below and from the day
each page first reached git, so nothing here needs dates by hand.

To add a guide:
  1. Copy a page in docs/guides/ as a template and write the new one.
  2. Add it to GUIDES with an icon, a title and a one-line summary.
     Optionally give it a shorter pitch for the homepage.
  3. Run this, look at the homepage and docs/guides/, and commit.

Icons are img:<file in docs/img/>, logo:<a mark in docs/logos.svg> or
glyph:<one of GLYPHS>.
"""
import datetime
import os
import re
import subprocess

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(REPO, "docs")
HOME_COUNT = 6
NEW_FOR_DAYS = 45

GLYPHS = {
    "download": '<path d="M12 3.5v11M7.5 10.5 12 15l4.5-4.5"/><path d="M4 15.5v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"/>',
    "home": '<path d="M4 10.5 12 4l8 6.5V19a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1z"/><path d="M9.8 20v-5.2h4.4V20"/>',
    "table": '<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M3.5 9.5h17M9.5 9.5v10"/>',
    "globe": '<circle cx="12" cy="12" r="8.5"/><ellipse cx="12" cy="12" rx="3.8" ry="8.5"/><path d="M3.8 9h16.4M3.8 15h16.4"/>',
}

# file: (icon, title, summary, homepage title, homepage pitch). The last two
# are only needed for guides that can appear on the homepage. Guides that went
# up the same day keep this order.
GUIDES = {
    "mac-vpn-split-tunneling.html": ("glyph:table", "Which Mac VPNs have split tunneling?",
        "Checked against each provider's own docs: who supports it on macOS, who doesn't, and the limits."),
    "split-tunneling-apps-mac.html": ("glyph:table", "Split tunneling apps for Mac, compared",
        "VPNonly, SplitTunnel and AppLanes side by side: price, how each routes apps, and which fits your setup."),
    "vpn-one-app-mac.html": ("img:google-chrome", "How to use a VPN for only one app on Mac",
        "Three approaches compared: per-app tools, a virtual machine, or PF and WireGuard yourself.",
        "Just your browser",
        "Chrome, Firefox, Arc or Brave on the VPN, while calls, banking and everything else stay on your normal connection."),
    "nordvpn-split-tunneling-mac.html": ("logo:nordvpn", "NordVPN split tunneling on Mac",
        "Why it isn't in their macOS app, and how to use your Nord subscription for one app anyway.",
        "NordVPN for some apps, not all",
        "NordVPN's Mac app has no split tunneling. Paste an access token into VPNonly and choose which apps use your NordVPN account."),
    "whole-mac-on-vpn.html": ("glyph:home", "Why does my whole Mac go through the VPN?",
        "What a VPN client changes on macOS, and the two ways to route only some apps.",
        "Your bank and calls stay home",
        "A normal VPN sends everything abroad, so banks ask questions and calls lag. Leave those alone and move only the app that needs it."),
    "mullvad-proton-split-tunneling-mac.html": ("logo:wireguard", "Split tunneling with Mullvad, Proton, IVPN or your own server",
        "Where to get a WireGuard config from each, and how to route one app through it.",
        "Mullvad, Proton or your own server",
        "Drop in a WireGuard config from your provider and pick the apps that use it. Your VPN's own app can stay closed."),
    "whatsapp-calls-mac-uae.html": ("img:whatsapp", "WhatsApp calls on a Mac in the UAE, without putting your bank on a VPN",
        "Only WhatsApp goes through the VPN. What we measured, and what can't be routed.",
        "WhatsApp calls from the UAE",
        "Only WhatsApp goes through the VPN, so your bank and local services still see you at home. The guide shows where the call packets actually went."),
    "mullvad-split-tunneling-mac.html": ("logo:mullvad", "Mullvad split tunneling on Mac",
        "Their app is exclude-only; use a config for the opposite. Tested, exit verified."),
    "protonvpn-split-tunneling-mac.html": ("logo:protonvpn", "Proton VPN split tunneling on Mac",
        "Where to get a WireGuard config from Proton, and how to route one app through it."),
    "surfshark-split-tunneling-mac.html": ("logo:surfshark", "Surfshark split tunneling on Mac",
        "Bypasser vs putting one app on Surfshark with a WireGuard config."),
    "ivpn-split-tunneling-mac.html": ("logo:ivpn", "IVPN split tunneling on Mac",
        "Generate a config from IVPN and route a single Mac app through it."),
    "airvpn-split-tunneling-mac.html": ("logo:airvpn", "AirVPN split tunneling on Mac",
        "Eddie can't split by app on macOS. Use a Config Generator file to put one app on AirVPN."),
    "windscribe-split-tunneling-mac.html": ("logo:windscribe", "Windscribe split tunneling on Mac",
        "Its app already has an inclusive mode. The config-generator route if you'd rather not run it."),
    "ovpn-split-tunneling-mac.html": ("logo:ovpn", "OVPN split tunneling on Mac",
        "OVPN's Mac app has no split tunneling. One zip of configs puts a single app on OVPN."),
    "azirevpn-split-tunneling-mac.html": ("logo:azirevpn", "AzireVPN split tunneling on Mac",
        "Get WireGuard configs from your AzireVPN account and route one Mac app through them."),
    "torguard-split-tunneling-mac.html": ("logo:torguard", "TorGuard split tunneling on Mac",
        "It works, but TorGuard's configs expire after 12 to 24 hours. How to set it up, and the catch."),
    "expressvpn-split-tunneling-mac.html": ("glyph:globe", "ExpressVPN split tunneling on Mac",
        "Its own app does it; why you can't pair ExpressVPN with a WireGuard tool."),
    "torrent-vpn-only-mac.html": ("glyph:download", "Torrents through the VPN on a Mac, and nothing else",
        "qBittorrent or Transmission on the VPN with a kill switch, while the rest of the Mac stays on its normal connection.",
        "Your torrent app, with a kill switch",
        "qBittorrent or Transmission goes through the VPN and is blocked if the tunnel drops. The rest of your Mac keeps its full speed."),
}

# Guides that never take the homepage's "newest" slot. A comparison sends
# readers to competitors, which is fine on the guides page but not as the
# first thing a buyer sees.
HOME_SKIP = {"split-tunneling-apps-mac.html"}

# After the newest guide, the homepage shows these, in this order.
PINNED = ["torrent-vpn-only-mac.html", "vpn-one-app-mac.html", "whatsapp-calls-mac-uae.html",
          "nordvpn-split-tunneling-mac.html", "mullvad-proton-split-tunneling-mac.html", "whole-mac-on-vpn.html"]


def published(href):
    """The day a guide first reached git; one that isn't committed yet is new today."""
    out = subprocess.run(["git", "-C", REPO, "log", "--diff-filter=A", "--follow", "--format=%cs",
                          "--", f"docs/guides/{href}"], capture_output=True, text=True).stdout.split()
    return out[-1] if out else datetime.date.today().isoformat()


def guides():
    found = []
    for order, (href, spec) in enumerate(GUIDES.items()):
        if not os.path.exists(os.path.join(DOCS, "guides", href)):
            raise SystemExit(f"GUIDES lists {href}, but docs/guides/{href} doesn't exist")
        icon, title, blurb = spec[:3]
        home_title, home_blurb = (spec[3], spec[4]) if len(spec) > 3 else (title, blurb)
        found.append({"href": href, "icon": icon, "title": title, "blurb": blurb, "home_title": home_title,
                      "home_blurb": home_blurb, "date": published(href), "order": order})
    missing = [f for f in os.listdir(os.path.join(DOCS, "guides"))
               if f.endswith(".html") and f != "index.html" and f not in GUIDES]
    if missing:
        raise SystemExit(f"add these to GUIDES first: {', '.join(missing)}")
    found.sort(key=lambda g: (g["date"], -g["order"]), reverse=True)
    return found


def icon(spec, prefix):
    kind, name = spec.split(":", 1)
    if kind == "img":
        return f'<img src="{prefix}img/{name}.png" alt="">'
    if kind == "logo":
        return f'<svg aria-hidden="true"><use href="#{name}"/></svg>'
    return ('<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" '
            f'stroke-linecap="round" stroke-linejoin="round">{GLYPHS[name]}</svg>')


def new_tag(g, newest):
    age = (datetime.date.today() - datetime.date.fromisoformat(g["date"])).days
    return ' <i class="tag">New</i>' if g is newest and age <= NEW_FOR_DAYS else ""


def replace_between(path, start, end, body):
    text = open(path, encoding="utf-8").read()
    text, n = re.subn(re.escape(start) + r".*?" + re.escape(end), lambda _: start + body + end, text, count=1, flags=re.S)
    if n != 1:
        raise SystemExit(f"{path} has lost its {start} marker")
    open(path, "w", encoding="utf-8").write(text)


def main():
    all_guides = guides()

    by_href = {g["href"]: g for g in all_guides}
    newest = next(g for g in all_guides if g["href"] not in HOME_SKIP)
    picks = [newest] + [by_href[h] for h in PINNED if h in by_href and h != newest["href"]]
    cards = "".join(
        f'      <a class="case" href="guides/{g["href"]}">\n'
        f'        <span class="ic">{icon(g["icon"], "")}</span>\n'
        f'        <span><b>{g["home_title"]}{new_tag(g, newest)}</b><span>{g["home_blurb"]}</span><em>{g["title"]}</em></span>\n'
        f'      </a>\n' for g in picks[:HOME_COUNT])
    replace_between(os.path.join(DOCS, "index.html"), "<!--HOME-GUIDES-->", "<!--/HOME-GUIDES-->", "\n" + cards)

    rows = "".join(
        f'  <a class="entry" href="{g["href"]}">\n'
        f'    <span class="ic">{icon(g["icon"], "../")}</span>\n'
        f'    <span><b>{g["title"]}{new_tag(g, all_guides[0])}</b><span class="bl">{g["blurb"]}</span>'
        f'<time datetime="{g["date"]}">{datetime.date.fromisoformat(g["date"]).strftime("%-d %b %Y")}</time></span>\n'
        f'  </a>\n' for g in all_guides)
    replace_between(os.path.join(DOCS, "guides", "index.html"), "<!--GUIDES-->", "<!--/GUIDES-->",
                    '\n<div class="index">\n' + rows + "</div>\n")

    sitemap = os.path.join(DOCS, "sitemap.xml")
    text = open(sitemap, encoding="utf-8").read()
    added = []
    for g in all_guides:
        loc = f"https://vpnonly.app/guides/{g['href']}"
        if loc not in text:
            text = text.replace("</urlset>", f"  <url>\n    <loc>{loc}</loc>\n    <lastmod>{g['date']}</lastmod>\n"
                                             f"    <priority>0.7</priority>\n  </url>\n</urlset>")
            added.append(g["href"])
    open(sitemap, "w", encoding="utf-8").write(text)

    print(f"{len(all_guides)} guides; homepage shows {', '.join(g['href'] for g in picks[:HOME_COUNT])}"
          + (f"; added to sitemap: {', '.join(added)}" if added else ""))


if __name__ == "__main__":
    main()
