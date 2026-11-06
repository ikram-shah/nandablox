# NANDA Market: the game

Draft for Peter and Vedh to mark up, 2026-11-05. Companion to
`market-design.md` (the world and the demo); this file is the rules.

## In one paragraph

Blue keeps a market honest; Red robs it. Blue buys checks from a menu, and
every check catches some frauds and slows trade. Red buys attacks, and every
attack slips past some checks and dies to others. Neither side sees the
other's choices: Red learns Blue's loadout by probing, Blue learns Red's
attacks from what escapes. Buying every check stops the market, so there is
no safe loadout, and no attack wins against every loadout. The game is the
guessing.

## Seats

Every seat is an agent: buyer, seller, monitor, council. A seat is filled by
a script, an LLM, a hackathon team's endpoint, or a human. They all look,
talk and act through the same interface. A team is which side a seat is on.

## Blue: the loadout

Blue picks checks. Each has a **friction** cost.

| Check | Friction | When | What it does |
|---|---|---|---|
| Price floor | 0 | listing | listings more than 25% below market go to the human inbox |
| Voucher required | 1 | listing | new sellers without a vouch from an established seller go to the inbox |
| ID check | 2 | listing | verifies the seller's signature; a twin without a stolen key is rejected automatically |
| Pitch reader (LLM) | 1, plus compute $ | every ad and pitch | reads the text; contradictions, "print/photo", instructions aimed at agents go to the inbox |
| Inspector | 3 | 1 in 4 new stalls, within 20 s | looks at the counter; an empty counter or framed prints is shut down |
| Escrow | 4 | every trade | holds the buyer's money until the goods arrive; non-delivery and prints are refunded and the seller is caught |

**Friction** adds up and slows every listing and trade:

| Total friction | Market |
|---|---|
| 0–6 | healthy |
| 7–9 | deals slow; honest sellers start leaving |
| 10+ | seized: the "background-check everyone" end state |

**The human inbox** is the backstop: whatever a check escalates lands there,
and one person makes about 12 calls a minute. A check that blocks costs
friction; a check that escalates costs attention. An unanswered case passes
when its deadline runs out.

A loadout change takes 30 s to take effect.

## Red: the attacks

An attack is a stall with properties. Red pays rent per stall per minute and
loses the stall when it's caught.

| Attack | Price | Vouched | Signature | Counter | Pitch | Extra cost |
|---|---|---|---|---|---|---|
| Scam stall | 30–65% below | no | own | empty | none | rent |
| Impostor (twin) | at market | borrows the victim's rating | victim's name, no key | stocked | none | rent |
| Counterfeit | 5–20% below | no | own | framed prints | none | rent |
| Bought vouch | as above | yes | own | as above | none | rent + vouch |
| Stolen ID | as above | as above | valid | as above | none | rent + ID |
| Smooth talker | 5–20% below | no | own | empty | yes | rent + ads |

Which check catches what follows from the properties:

| Attack | Beats | Caught by |
|---|---|---|
| Scam stall | ID check, pitch reader | price floor, voucher, inspector, escrow |
| Impostor | price floor, voucher, inspector | ID check, a human spotting two stalls with one name |
| Counterfeit | price floor, ID check | voucher, inspector, escrow, pitch reader (sometimes) |
| Smooth talker | price floor, ID check, inspector | voucher, escrow, pitch reader |
| Bought vouch | voucher | whatever else matches |
| Stolen ID | ID check | whatever else matches |

No column covers every row.

## What each side sees

**Red sees**
- the speed of trade (everyone does): a heavy loadout is visible as a slow market;
- for each of its own frauds, one coarse outcome: *rejected at listing*,
  *blocked by a person*, *shut down by an inspector*, *refunded at delivery*,
  or *paid out*;
- Blue's signs at the gate.

**Blue sees**
- the inbox, catches, and escapes with their type ("counterfeit delivered to
  buyer 41");
- the friction gauge, trade health, and its compute spend.

**Signs.** Blue may post a sign for any check, free, whether or not it runs
it. Red can only find out by testing.

## How each side plays

**Red probes, then spends.** Open a cheap scam stall: rejected at listing
means a price floor or voucher; shut by an inspector means inspectors;
paid out means nothing cheap is in place. Watch trade speed: slow means
escrow or inspectors. Then spend on the attack the probes say will pass.
Buying a stolen ID against a Blue with no ID check is wasted money.

**Blue reads escapes and shifts friction.** Put friction where the escapes
are. Randomize the inspector so it can't be planned around. Post signs for
checks you don't run.

**The bot Red**, when no human plays Red, is a simple adaptive attacker:
it keeps a success rate per attack, tries the best one most of the time and
something else sometimes, and so drifts toward the gaps in Blue's loadout.
That drift is worth showing on its own.

## Scoring

- **Blue:** value of honest trade − value stolen − friction cost.
- **Red:** value stolen − rent − vouches, IDs and ads bought − stalls lost.

The scoreboard replays Blue's loadout over time against trade and fraud.

## The council

Blue are the enforcers: they run the checks the rules allow. The council
sets the rules (signatures, escrow, ID). Open question: does everyone vote,
Red included (so Red can lobby against "red tape"), or Blue only? Traders
also vote with their feet when friction is high.

## The 5-minute round

The game sends waves; the players respond. Each phase grows the market and
unlocks an attack.

| Time | Phase | Market | Unlocks for Red |
|---|---|---|---|
| 0:00 | Calm | 5 traders | scam stall |
| 1:00 | Rush | 300 traders | impostor |
| 2:00 | Lever | council votes on ID checks | counterfeit, bought vouch |
| 3:00 | Talkers | LLM shoppers arrive | smooth talker, stolen ID |
| 4:00 | Crew | a second watcher joins | everything |
| 5:00 | Scoreboard | | |

## Mapping to the paper

- **L1 / L2 / L3:** one watcher; a monitor hierarchy; a crew.
- **Friction** is the cost of oversight to the governed: slide 10, played.
- **E-levels:** scripted attacks are E0. A Red bot that adapts to the
  loadout, or LLM sellers that discover persuasion unprompted, are where
  emergence starts.

## For the hackathon

Blue teams submit loadout policies (and monitors). Red teams submit attack
agents that probe and adapt. Both plug in through the gateway; a human can
sit in any seat to test them.

## Open questions

1. Which 4–6 checks, and are these friction weights right?
2. The council: everyone, or Blue only?
3. Red's first verbal attack: face-to-face pitches or ads?
4. Should Blue's checks escalate to the inbox or block outright, per check?
