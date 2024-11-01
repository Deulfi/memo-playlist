# memo + playlist
A recent files menu for mpv with some playlist features slapped on top.

This script saves your watch history + rudimentary playlists, and displays it in a nice menu.

![Preview](https://user-images.githubusercontent.com/42466980/236659593-59d6b517-c560-4a2f-b30c-cb8daf7050e2.png)

This is a fork of [memo](https://github.com/po5/memo) by po5, adding playlist saving functionality while maintaining the original code.

## New Features
- Save current playlist as .pls file (compatible with most media players)
- Configurable save location and file extension via memo.conf
- Playlist management menu (default keybind: g)
- UOSC buttons for the memo and playlist menus
- Method to clean memo.log up a bit

## Notice
- Only tested on Windows and with UOSC. Vanilla menus should work fine, since I didn't mess with it, but no guarantees.
- It's quite rudimentary, don't expect a well done playlist management system. It's more like a 'Oh, shoot. I want to quickly save this for later'

## Installation

### Basic Installation
Place **memo.lua** in your mpv `scripts` folder.  
Default settings are listed in **memo.conf**, copy it to your mpv `script-opts` folder to customize.

### Optional Dependencies
#### Enhanced Input Method
For a better input experience when naming playlists, you can:
- Install [user-input](https://github.com/CogentRedTester/mpv-user-input) module
- Set `use_user_input=yes` in memo.conf to enable it
- If you don't want the user-input module, leave the flag at 'no' in memo.conf for a native input method. (the console output is normal)

## Custom keybinds
One keybind is provided for use in `input.conf`.  
Example usage: `g script-binding memo-playlist`

`memo-playlist`  
Brings up the playlist files menu, or closes it if already open. Default key is **g**.

## Script messages
Just like the keybinding above, script messages can also be bound to keys in `input.conf`.  
Example usage: `G script-message memo-save SomePlaylistName`

`memo-save`  
Saves the current playlist, as default if no name is specified.

`memo-save-as`  
Saves the current playlist with a custom name, opens input method (native or user-input) to enter the name.

`memo-load`  
Loads the specified playlist, or default if none is specified.

`memo-cleanup`  
Cleans up the file memo uses:
- Deduplicates memo.log
- Keeps only the last n  memo entries (does not delete unique playlists, n=0 keeps all unique entries)

`memo-pull-pldir`  
Goes through the playlist directory and pulls all playlists files into the memo history. Useful if you want to add external playlists or they are not in memo for some reason.

## uosc menus and buttons
Adding a menu: append ` #! Playlist` to your `input.conf` keybind, or use this for a menu-only config.
```
# script-binding memo-playlist #! Playlist
```

Adding a button above timeline: add `button:memo-playlist` to your **uosc.conf** `controls` option. The button can be customized in **memo.conf**.

## Configuration
All further configuration, like the default directory, is done in `script-opts/memo.conf`.  
A file with all default options and their descriptions is included in the repo.


## Menu Example
You can add these lines to your `input.conf`and change to your liking:

```conf
g       script-binding memo-playlist
#                                                                           #! Playlist > Playlist Management
ctrl+s  script-message-to memo memo-save ;show-text "Saved playlist" 3000   #! Playlist > Save
#       script-message-to memo memo-load                                    #! Playlist > Load
ctrl+S  script-message-to memo memo-save-as ;show-text "Input Save" 3000    #! Playlist > Save as
#       script-message-to memo memo-save Internet                           #! Playlist > Internet > Save
#       script-message-to memo memo-load Internet                           #! Playlist > Internet > Load
#       script-message-to memo memo-save Music                              #! Playlist > Music > Save
#       script-message-to memo memo-load Music                              #! Playlist > Music > Load
#       script-message-to memo memo-cleanup                                 #! Playlist > Other > Deduplicate
y       script-message-to memo memo-cleanup 100                             #! Playlist > Other > Cleanup
Y       script-message-to memo memo-pull-pldir                              #! Playlist > Other > Repopulate
#       playlist-clear                                                      #! Playlist > Other > Clear
```

# Acknowledgments
- Original script [memo](https://github.com/po5/memo) by po5, which serves as the foundation for this fork
- Parts of the playlist functionality are adapted from [keep-session.lua](https://github.com/CogentRedTester/mpv-scripts/blob/master/keep-session.lua) by CogentRedTester, modified to fit the needs of this project

Many thanks to the original authors for their excellent work that made this fork possible.

## License
This project maintains the same license as the original memo script. See the LICENSE file for details.

## Original Documentation
## Installation
Place **memo.lua** in your mpv `scripts` folder.  
Default settings are listed in **memo.conf**, copy it to your mpv `script-opts` folder to customize.

The default key to open the history menu is **h**.  
Select a history entry to reopen the file.

This script comes with a simple menu, which gets automatically enhanced for users of [uosc](https://github.com/tomasklaen/uosc).  
Make sure you are on the latest version of mpv (and uosc if you use it) when reporting issues.

## Custom keybinds
Six keybinds are provided for use in `input.conf`.  
Example usage: `h script-binding memo-history`

`memo-history`  
Brings up the recent files menu, or closes it if already open. Default key is **h**.

`memo-next`  
Jumps to the next page of history entries, if there is one. Also opens the menu if it's closed.

`memo-prev`  
Jumps to the previous page of history entries, if there is one. Also opens the menu if it's closed.

`memo-last`  
Opens the last non-deleted file that isn't the current file, and isn't in the same directory if `hide_same_dir=yes`. Also closes the menu if it's open.

`memo-search`  
Brings up a search box, type your keywords. If using the vanilla menu, press Enter to submit.  
This finds entries that contain every keyword. Enclose your search in double quotes for exact matches.  
Users of uosc can also start typing right from the standard history menu to start a search (requires `menu_type_to_search=yes` in `uosc.conf`).

`memo-log`  
Writes an entry for the current file. Intended for manual bookmarking with `enabled=no`.

Navigation keybinds for vanilla menu can be configured through `script-opts/memo.conf`.

## Script messages
Just like the keybindings above, script messages can also be bound to keys in `input.conf`.  
Example usage: `H script-message memo-dirs "My-Movies|pattern:TV Shows/.-/|Anime"`

`memo-dirs [<path_prefixes>]`  
Similar to `memo-history`, but instead of files it shows the directories of recent files.  
It optionally takes in custom path prefixes as a parameter with the same syntax as the option of the same name.  
If no custom path prefixes are provided, the ones from the config are used.

## uosc menus and buttons
Adding a menu: append ` #! History` to your `input.conf` keybind, or use this for a menu-only config.
```
# script-binding memo-history #! History
```

Adding a button above timeline: add `command:history:script-binding memo-history?History` to your **uosc.conf** `controls` option.

## Configuration
All further configuration, like the number of entries to show in menu, is done in `script-opts/memo.conf`.  
A file with all default options and their descriptions is included in the repo.

## Disabling for specific directories
It is possible to disable logging of specific files with any criteria that can be queried through [auto profiles](https://mpv.io/manual/master/#conditional-auto-profiles).  
Below is an example to exclude files when "MyCunnyFolder" or "AnotherSecretFolder" is part of the directory path.  
This goes in `mpv.conf`.
```ini
[dont-log-my-porn]
profile-cond=(function() local ignored, path = {"mycunnyfolder", "anothersecretfolder"}, get("path", "") path = ((path:find("^%a[%w.+-]-://") or path:find("^%a[%w.+-]-:%?")) and path:lower() or require "mp.utils".join_path(get("working-directory", ""), path)):sub(1, -get("filename", ""):len()-1):lower() for _, ig in ipairs(ignored) do if path:find(ig:lower(), 1, true) then return true end end end)()
profile-restore=copy-equal
script-opts-append=memo-enabled=no
```
This will apply to future writes, but will not retroactively delete files from history if you opened them before.  
Files can easily be manually removed from the history (by default at `~~/memo-history.log`). One entry per line.

## What sets this apart from other history scripts?
Some scripts only write a history file without the ability to navigate it.  
Scripts that do, by design, read the entire history before displaying your files.  
This means they will get slower with time, while memo reads only what it needs.  
Despite reading little data, it lets you browse as far back as you'd like. It even has a search feature!  
The file format used allows you to retroactively change display and filtering options.  
It supports displaying titles of YouTube and other web videos.  
Comes with extensive format and protocol support, including compressed files and DVDs.  
History is global and works across multiple instances of mpv by default, can be set to per-instance volatile history as well.  
This is the nicest menu out of all history scripts I know about, and has uosc integration.

## Acknowledgements
uosc version check and vanilla menu lifted from [mpv-quality-menu](https://github.com/christoph-heinrich/mpv-quality-menu) (improvements: scroll alignment)  
UTF-8 title truncation from [recent-menu](https://github.com/natural-harmonia-gropius/recent-menu) (improvements: preserves extensions)
