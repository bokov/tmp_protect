## Usage

**./tmp_protect.sh :** runs with default settings on your /tmp directory

**./tmp_protect.sh --config <your_custom_config.json> :** runs with a custom settings file you get by copying and modifying tmp_protect_config.json

**./tmp_protect.sh --dry-run :** this script hasn't been tested enough yet to actually put real files at risk, so for now it is in dry-run mode whether you use this setting or not


## Config Settings

A file named tmp_protect_config.json in the same directory as tmp_protect.sh will be treated by tmp_protect.sh as the default config file.

**global**

* **source_dir :**  The directory you are trying to sort out
* **destination_dir :** Where the files that need to be reviewed will move
* **match_git_status :** Some people like to pull git repos into /tmp so they don't get too attached to them. But it would be nice to commit and push the ones that need it before blowing them all away. 
    And how to easily even tell which of hundreds of folders are git repos? Well, with this setting enabled (default) all top-level git repos will be identified and flagged as "dirty" (untracked files or
    uncommitted changes) or "ahead" (local changes that have not been pushed yet). By default, both are enabled. This way you can leave "clean" git repos alone to be deleted and or ahead ones can be moved
    to another location for you to review at your liesure. By the way, bare git repos are as yet all treated as "ahead" until I write the extra code necessary to test them for unpushed changes (they can't 
    be "dirty" for obvious reasons).
* **uids :** You probably don't want to curate automated files created by system processes. I for one only ever need to review my own files. If populated, this field tries to ignore files that do not match
    any of the uids you specify

**unmatched_dirs :** What to do with directories that didn't match any other criteria.

**section** Contains any number of sections that will handle groups of files. A group of files is usually inside the same directory as identified by name patterns (match_dir) or contents (match_contents). 
If a section contains neither that means it applies all the flat-files in the directory specified by source_dir (other sections apply to either flat-files or subdirectories). The use of max-age, min-age, 
max-size, min-size, extensions_whitelist, extensions_blacklist, regexp_whitelist, or regexp_whitelist will cause the script to descend to the top levels of the matched directories copying or not copying individual 
top-level files and folders. On the other hand if a section contains nothing but match_contents or match_dir, description, and action then whatever directories match will be copied as one unit. I have no 
idea what happens if you use both match_dir and match_contents in the same section. It will probably OR the two criteria together.
The following settings are supported

* **skip :** If this is found, section that contains it is ignored, though not guaranteed to work outside of sections nested inside of "section".
* **description :** Not used by script, for documentation purposes only.
* **match_dir :** A regexp pattern for matching types of directories.
* **match_contents :** A set of regexp patterns *all* of which should be matched by files in a directory for that rule to apply to it (if you need to OR the regexps instead of AND them, you can just have one
  regexp with `|`s in it).
* **action :** Either 'move', 'log', or 'ignore'. 'move' will copy the entire directory or file to destination_dir. 'log' will leave it where it is but log its existence-- possibly useful to reconstruct what
  you need to re-download later, or what you need to add to your filters. 'ignore' will try to generate as little output about it as possible.
* **max-age, min-age, max-size, min-size :** Upper and lower limits for those features of a file.
* **extensions_whitelist, extensions_blacklist, regexp_blacklist :** Each of these gets concatenated into a single `|`-delimited regular expression, but the extensions ones are a convenience that take care of
  putting on the leading dot and trailing `$` for you.
* **regexp_whitelist :** Not yet implemented, so ignored. When it is implemented, unlike all the others, if multiple patterns are given they will *all* have to match for the criterion to be met.
* **size-limit :** Maybe your destination_dir is not as big as your source_dir. The eventual plan is to limit how much data total can get moved there. Currently this setting is not implemented and is ignored
* **prioritize-by :** Also not implemented. When it is, it will control the order in which files get moved when size-limit is being enforced.
    
