# Meio DPS

## 1.3.0

- GCD line on every spell and ability: the global cooldown it starts (1.5 s, 1 s for
  rogues' attacks), or "none" for one you can use straight after another, handy for
  macros. From the game's own spell data. Off with `/meiodps gcd` or Settings > GCD

## 1.2.0

- Damage on action buttons is now off by default. This update turns it off once for
  everyone, since the last version saved it as on whether you chose it or not. To have it
  back: `/meiodps buttons on`, or Esc > Options > AddOns > MeioDPS > Show on buttons. What
  the buttons show (expected, measured or DPS) is kept
- Numbers on Bartender4, ElvUI and Dominos buttons too
- Fixed: a button's number no longer runs into a big reagent count (Soul Fire with 20+
  shards): it moves above the count, and back to the middle when the count goes

## 1.1.0

- Damage on action buttons: each damage spell's damage per cast in small text on its
  button (or measured per cast, or DPS); Settings > Action buttons, `/meiodps buttons`

## 1.0.1

- Fixed: pressing Shift over a tooltip could cause a Lua error in combat later (the refresh
  tainted Blizzard's tooltip). Action bar and bag tooltips still update on Shift; elsewhere,
  hover again with Shift held

## 1.0.0

- First release: damage, DPS and damage per mana, rage or energy on spell and ability
  tooltips; damage per swing or shot on Attack, Auto Shot and Shoot; weapon tooltips show
  their DPS with your attack power; Measured: what each spell, shot and your melee really
  did in your fights, from the damage meter
