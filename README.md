# BenisAH

An auction house tab for World of Warcraft that hunts for cheap buyouts. Works
on the modern auction house (`C_AuctionHouse`), so on both WoW Forever
(Interface 16001) and retail Midnight (Interface 120100).

Open the auction house and pick the **BenisAH** tab.

## Modes

### Below vendor price

Press **Scan**. BenisAH browses the selected auction house categories and
lists every auction whose buyout is lower than what a vendor pays for the
item. The **Categories** button picks which categories are scanned (all by
default). **Min profit** leaves out rows whose total profit (vendor price
minus buyout, times the amount available) is below it; it applies from the
next scan.

### Item name and max price

Type an item name and the most you want to pay per item, then press **Scan**
(or Enter). Every auction of a matching item at or under that price is listed.
Tick **Exact name** to match the whole name instead of a part of it.

### Watch one item

For sniping a single item, such as Silk Cloth. Type its exact name and the
most you want to pay per item, then press **Watch** (or Enter). The first
check browses for the item to find it. After that, every check sends only
that item's own search query, with no browse step and no other items, so a
cheap auction shows up about one query (plus the delay) after it is posted.
The item is browsed for again once a minute, to pick up item levels that
appeared later.

With **Sound** ticked, a new auction within the limit plays a raid warning
sound and flashes the game's taskbar icon. On a stackable item, more units
within the limit count as new, so you are told when someone else posts too.
Buying still takes a click.

### Upgrades

Lists, for each selected equipment slot, the auction that improves the most
on what you have equipped, at or under **Max each** (0 means no limit). The
cheaper auction wins a tie.

For free upgrades, tick **Free** in **Weights & options**. An upgrade may then
cost at most what a vendor pays for the item it replaces, so selling the old
piece pays for the new one. **Max each** turns into **Sell price +**, an amount
you are willing to add on top (0 = free only). A slot with nothing equipped
only gets that amount. A damaged item sells for less, and the limit uses what
it sells for now, so repairing it raises the limit.

- **Slots** picks the slots to search. Rings and trinkets are compared with
  the weaker of the two you wear, and the same ring or trinket is not
  suggested twice.
- Armor slots only search the heaviest armor type you can wear (mail for a
  shaman from level 40 on the older rule sets). **Weights & options** can
  override this.
- Weapons follow what you have equipped. A two-hander is matched with
  two-handers, dual wielding with one-handers in each hand, and a one-hander
  with a shield or off-hand item with the same again. Weapon types you cannot
  use are skipped, as is anything whose tooltip shows red text.
- Items up to your level are searched. **Max required level** in
  **Weights & options** raises that limit, for example to plan ahead.

An item's score is each stat times its weight, plus weapon DPS times the DPS
weight, plus (speed - 2.0) times the speed weight, so slow weapons win at a
similar DPS. The **Score** column shows the new item's score and **Gain**
shows how much it adds. Hover the item to see what it replaces. The weights
start at an Enhancement Shaman preset (weapon DPS, then Hit, Expertise,
Strength, Intellect and Spell Power), and you can edit them or reset them to
that preset. Changes apply from the next pass.

Items with a random suffix ("of the Bear") or another item level have to be
looked up one by one, so the first pass takes longer. Later passes reuse what
was found and only look again at items whose price or quantity changed.

## Scanning

The scan loops until you press **Stop**, switch to another tab or close the
auction house. **Delay** is the pause in seconds between two
server queries (0.2 to 60, also `/bah delay <seconds>`); it comes on top of the
server's own throttle. Passes after the first only re-check items whose lowest
price or quantity changed.

The newest finds are on top. Auctions that were bought (**Bought**) or sold
or expired (**Gone**) turn grey and move below the live rows, the latest
first; the list keeps the last 100 of them. Rows never move while the mouse is over the button columns (amount,
Buy, refresh, View) or while you type an amount, so a row cannot slide under
the cursor right before a click.

## Buying

- **Single items**: one click on **Buy** buys the item at its buyout. A seller's
  identical auctions show as one row with a count; the button then reads
  **Buy 1**, each click buys one item, and the row reloads in between.
  Total and Profit on such a row are for the whole lot.
  The game only buys an auction whose item it has loaded, and it keeps only
  the item searched last loaded. So pointing at **Buy** loads that item, and
  the scan waits while the mouse stays there. A click that comes before the
  item is loaded loads it instead (the button shows **...**); click again
  once it reads **Buy**.
- **Stackable items**: type how many you want in the box next to **Buy**
  (it starts at everything available within the limit). One click asks the
  server for a price quote, and the quote is confirmed automatically if its
  total is within quantity x limit (the vendor price or your max price). A
  dearer quote is cancelled. If the server does not act on the automatic
  confirm, the button changes to **Confirm** and a second click completes it.

The refresh button next to **Buy** looks up that one item's auctions again,
ahead of the scan (or on its own when no scan is running), and resets the
amount box to what is available now.

**View** opens the item in Blizzard's Buy tab, as if you had clicked it in
the browse results. That reloads its auctions from the server, and for a
single auction it selects that auction, so the default Bid and Buyout buttons
are ready. Leaving the BenisAH tab this way stops the scan.

Shift-click an item to link it in chat.

Below the list, **This session** adds up what you bought since the auction
house was opened: the profit (vendor price minus what you paid, in vendor
mode), how many items and what they cost. Closing the auction house resets it.

## What the auction house API does not allow

- Nothing is bought without a click: the game only accepts purchases from a
  hardware event, one purchase per click.
- Results cannot be sorted or filtered by post time, so there is no "newest
  first".
- Only buyouts are considered; bid-only auctions are ignored.
- Your own auctions (this character's or the account's) are skipped.

## Other addons

If LibAHTab is loaded (Auctionator ships it), the tab is created through it
and sits in the same row as the other addon tabs. Without it BenisAH adds its
own tab.

## Install

Symlink or copy the folder into your AddOns directory:

```
ln -s /path/to/BenisAH "<WoW>/_forever_/Interface/AddOns/BenisAH"
```

## Commands

- `/benisah` or `/bah` - help
- `/bah delay <seconds>` - pause between server queries
- `/bah stop` - stop a running scan
