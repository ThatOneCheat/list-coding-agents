# 🤖 coding agents finder thingy

ok so basically i kept installing like a lot of ai coding agents (claude, gemini, codex, kimi, all of them ) and then i completely forgot which ones i even had so i made this. it just looks at your pc and tells you which coding agents you got. that's it. that's the whole script

idk how it works i vibe coded it on a random day 

## what it does

- finds all the ai coding agent CLIs on your windows machine
- tells you HOW you installed each one (npm vs winget vs just i think a curl installer)
- auto detects new ones so i dont goota edit it when an new agent drops
- spits out a a good html file 

it does NOT show random apps or windows stuff. only the agents or cli 

## how to run it

open powershell in the folder and just:

```powershell
.\list-coding-agents.ps1
```

it prints everything AND opens a html report in your browser!

### extra command you can try

```powershell
.\list-coding-agents.ps1 -CheckUpdates     # tells u which agents are outdated + the exact command to update them
.\list-coding-agents.ps1 -Json             # dumps everything into coding-agents.json if u wanna script with it
.\list-coding-agents.ps1 -IncludeEditors   # also show cursor / windsurf / kiro (the gui ones!)
.\list-coding-agents.ps1 -ShowReasons      # tells you WHY it thinks something is an agent
.\list-coding-agents.ps1 -NoHtml           # skip the html if u just want the terminal
.\list-coding-agents.ps1 -NoOpen           # still writes the html but doesnt pop the browser (for scripts n stuff)
```

## ok it got a big upgrade

so i went back in and made it way more useful, now it also:

- shows the VERSION of every agent. even the sneaky exes with zero metadata, it literally runs them with `--version` and just asks (with a timeout so a weird one cant freeze the scan)
- shows how much disk space each agent is eating. mine was 2.4 GB of coding agents... yeah
- guesses when u last used each one by peeking at its config folder (like `~/.claude` and stuff)
- `-CheckUpdates` checks npm + winget and tells u exactly whats outdated, with the copy paste command to fix it
- remembers ur last scan in `last-scan.json`, so next run it goes "yo u installed 2 new agents since last time". it even tells u when one disappears
- `-Json` dumps the whole thing to a json file with all the data (versions, sizes, update commands, everything)

and the html report got fancy too. theres a search box now (press `/` to jump to it, esc to clear), version badges on every agent, lil chips showing size and when u last used it, a NEW tag on stuff u just installed, and if somethings outdated theres a yellow update pill u can literally CLICK and it copies the update command. thats it, u click, u paste, ur updated

## how does it even know what's an agent??

honestly it's just read the metadata of the app packages but like.... it checks stuff like:

- npm package descriptions + keywords (some literally say "coding agent" so its easy to understand)
- if the package depends on ai sdks (anthropic, openai, etc)
- the little info baked into `.exe` files (claude says "Anthropic" in there and stuff)
- winget publishers like `OpenAI.something`
- the name itself (if it has "cli" + a model name it's probably an agent!)

then it gives each thing a **score**:

| tier | meaning |
|------|---------|
| ✅ **DETECTED** | yep that's an agent, the ps1 file is Suree|
| 🤔 **POSSIBLE** | idk man maybe?? you check it( the ps1 file is unsure) |

## the one thing it CANT do...

some agents are just a random `.exe` with no info and a weird name (looking at u `agy` ). like there is LITERALLY nothing on your pc that says what they are. no app can guess that, not even mine, sorry.

so for those there's a lil file called **`agents-extra.txt`**. just type the command name in there (one per line) and it'll force it to show up. done.

```
# agents-extra.txt
blackbox
agy
```

## requirements

- windows + powershell (it comes with windows so ur good)
- thats it??? yeah thats it

---

made this cuz i was tired of forgetting what i installed if it helps u too then cool and just star it or whatever idk im just a vibe coder
