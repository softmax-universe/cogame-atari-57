# Writing a lane stance

A policy on this cabinet returns one stance. Every 5 seconds the game server hands
your player its own board view and asks for one JSON object; a deterministic
autopilot then runs that object 24 times a second for the next 120 ticks. You
never touch a joystick — you choose **what to go for** and **how much risk to
take**.

## The reply

Minimal valid reply:

```json
{"mode": "hunt"}
```

Full reply with optional settings:

```json
{"note": "power pellet 62 ticks away in sw and nothing is chasing me there; take it, then cash the chain",
 "mode": "hunt", "zone": "sw", "risk": 0.55, "lead_ticks": 16,
 "fire": "auto", "say": "going for the power"}
```

| field | type | required | default when omitted | legal values |
|---|---|---|---|---|
| `mode` | string | **required** | — | `clear`, `hunt`, `strike`, `safe`, `bank` |
| `zone` | string | optional | `"none"` | `nw`, `ne`, `sw`, `se`, `centre`, `left`, `right`, `top`, `bottom`, `none` |
| `risk` | number | optional | `0.5` | finite JSON number in `[0, 1]`, quantised to a permille |
| `lead_ticks` | integer | optional | `14` | JSON integer in `[0, 48]` |
| `fire` | string | optional | `"auto"` | `auto`, `hold`, `never` (GALLERY only) |
| `note` | string | optional | `""` | ≤ 160 runes (truncated on a rune boundary) |
| `say` | string | optional | `""` | ≤ 48 runes (truncated, then printable-ASCII sanitised) |

**Parsing is strict.** Reply with a single canonical JSON object, optionally
wrapped in a standard outer Markdown JSON fence (` ```json ... ``` ` or
` ``` ... ``` `). Only `mode` is required; omitted optional fields always take
the fixed documented defaults above (never inherited from a previous turn).
Surrounding prose, synonyms, numeric strings, percentages, out-of-range values,
and invalid supplied optional fields are rejected (never guessed or corrected).
After one retry, a failed model turn records a missed turn (`fallback` +
`missed_turn`), synthesizes no stance, and emits a zero physical control byte
(`0`).

## What each mode does

| mode | what the autopilot does |
|---|---|
| `clear` | weights every target by `value / distTicks` — take the nearest scoring thing, over and over. The default. |
| `hunt` | weights by `value^1.5 / distTicks` — go for the highest-value thing reachable even if it is far. |
| `strike` | as `hunt`, but ×3 on fleeing hunters (`chomper`), the top two brick rows (`brickfall`) and the saucer / top rank (`gallery`). This is the cash-in stance. |
| `safe` | as `clear`, scaled by each target's own `min(1, threatEta/48)` — keep the largest distance from every threat that still scores. |
| `bank` | as `safe`, and any target whose route enters a tile a hostile can reach within 24 ticks is **removed** from the set. You will score slowly and you will not die. |

`zone` multiplies every target outside it by 0.35 — a bias, not a fence.

`risk` sets the **danger gate**: a move into a tile whose threat ETA is below
`(1 - risk) · 96 + 4` ticks is rejected outright. At `risk = 0` nothing may come
within four tiles; at `risk = 1` threats are ignored entirely. In `gallery` it
also decides how early the paddle steps out of a falling bolt's column: a paddle
that only dodges in `safe` dies with a full magazine.

`lead_ticks` is how long the autopilot commits to a chosen route before
re-deciding — but the danger gate can always break a commitment early.

`fire` matters only in `gallery`: `auto` fires whenever a bolt slot and the
reload allow, `hold` fires only when the paddle is lined up on the lowest live
marcher in its column, `never` holds fire.

## What you can see

Your **own whole screen** — every tile, every sprite, your avatar, your lives,
your points — plus:

- `threats`: every hostile in your lane, sorted by `eta_ticks` ascending;
- `targets`: up to 12 scoring things, sorted by `value / dist_ticks`, each with
  its zone and whether it is `safe`. **This is the same array the autopilot
  weights**, so you are never guessing at a quantity the engine already knows;
- `zones`: the five fixed regions with their total target value and the soonest
  a hostile can be in them;
- `scoreboard`: every rival's `alias`, `score`, `lives` and `screen` — the
  entire cross-lane surface, and read-only.

You cannot see any other lane's board, sprites, stance, note or policy, the
seed, any RNG state, any future draw, any wall-clock fact, or who holds any
seat, including your own.

## Two worked stances

**Cash a chain.** `power_ticks_left` is above 60, so the four hunters are
fleeing for another 2.5 seconds and the chain pays 100 + 150 + 200 + 250:

```json
{"note": "power window open with 2.5s left; three hunters within 5 tiles",
 "mode": "strike", "zone": "none", "risk": 0.85, "lead_ticks": 10,
 "fire": "auto", "say": "chain time"}
```

**Protect a lead.** You are ahead on the scoreboard with 25 seconds left; a life
is worth 1.000 and 200 more points are worth 2.000, but a death costs 1.000 and
the clock:

```json
{"note": "leading by 4.2 with 25s left; nothing is worth a life now",
 "mode": "bank", "zone": "none", "risk": 0.1, "lead_ticks": 12,
 "fire": "auto", "say": "sitting on it"}
```

## The published baselines

Both ship in the same image and emit the identical object, so they are directly
comparable with prompt and trained policies.

**`arcader`** (`PLAYER_SCRIPTED=arcader`) — the certification player and the
default scripted baseline:

1. lane over → `safe`, risk 0, `fire: never`;
2. else `powerTicksLeft > 48` → `strike`, risk 0.85, lead 10;
3. else the nearest threat inside `panicTicks` (20) → `safe`, risk 0.15, lead 8;
4. else a power pellet within 72 ticks → `hunt` in that pellet's zone, lead 16;
5. else `clear` in the zone with the most target value;
6. and in every branch, on the last life: halve the risk and demote `hunt` to
   `clear`.

**`hoover`** (`PLAYER_SCRIPTED=hoover`) — deliberately different in shape and
weaker: `{"mode":"clear","zone":"none","risk":1.0,"lead_ticks":24,
"fire":"auto"}` every turn. It never dodges. It banks points fast and dies fast,
which gives the ladder a spread.

`arcader`'s three tunables (`panicTicks`, `riskMilli`, `leadTicks`) are a
`BaselineParams` object rather than literals because they were **chosen by a
grid sweep**, not guessed: `tools/tune_baselines.nim` plays four `arcader`s over
a 4 × 3 × 3 matrix across all three ROMs and six seeds,
`tools/ci/baseline_tuning.json` records the whole grid and the pick, and
`tests/test_tuning.nim` re-asserts that the shipped defaults still equal it.
