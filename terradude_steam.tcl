# TeRRaDuDe Steam.tcl - Steam game info for Eggdrop
#
# Usage in the channel:
#   !steam cyberpunk        searches by name and shows the details of the best match
#   !steam 1091500          shows the details for this App ID directly
#   !steam Some.Game.v1.2-GROUP   release-style names are cleaned up first
#
# All replies go to the channel where the command was given.
# What you want to see, where it works and how it is coloured is set in the
# CONFIG block below.
#
# Requirements (Debian): apt install tcl-tls tcllib
# Eggdrop: 1.8 or newer, bot set to UTF-8 (see 'encoding system' in your eggdrop.conf)

# ---------------------------------------------------------------- CHANGELOG
# 1.6 (2026-11-24)
#   - Colour now covers all output: game name (color_title, default 03),
#     description and status/error messages (color_text, default 14) and
#     URLs (color_url, default 03). Set any of them to "" to leave it plain.
#   - "Searching for:" is now a normal label/value field.
# 1.5 (2026-11-24)
#   - Added optional colour output. New config options: use_color,
#     color_label (default 14, grey), color_value (default 03, green),
#     color_title (default none, bold only).
#   - Colours and bold are stripped automatically in channels with mode +c.
#   - URLs are never coloured, so IRC clients can still make them clickable.
# 1.4 (2026-11-24)
#   - Fix: "bad option" error in release_to_title. The regsub pattern that
#     strips the -GROUP suffix started with a dash and was read as an option;
#     added "--" before the pattern.
# 1.3 (2026-11-23)
#   - Added release-name parsing: Some.Game.v1.2-GROUP is turned into a clean
#     search term. New config options: parse_release, show_parsed.
# 1.2 (2026-11-23)
#   - All script text (comments, replies, errors) is now in English.
#   - Default lang changed from dutch to english.
# 1.1 (2026-11-23)
#   - Added CONFIG block: per-field show_* toggles, channel list, trigger,
#     cooldown, description length, number of alternatives and screenshots.
#   - Replies always go to the channel where the command was given.
# 1.0 (2026-11-23)
#   - Initial version: !steam <name or App ID> using the public Steam
#     storefront endpoints (storesearch and appdetails).
# -------------------------------------------------------------------------

package require http
package require tls
package require json

namespace eval ::steam {

    # ============================ CONFIG iNFO ==========================
    # 1 = show, 0 = hide
    # channels:  list of channels where the script works, for example {#channel #other}. An empty list {} means: all channels.
    # country:   store region, decides the currency (NL = euro).
    # lang:      language of the Steam results (english, dutch, german, ...).
    # cooldown:  seconds between two lookups per channel.
    # maxdesc:   maximum length of the description in characters.
    # maxalt:    number of extra search results to list.
    # maxshots:  number of screenshots to show (needs show_screenshots 1).
    # parse_release: turn a release-style name like Some.Game.v1.2-GROUP into a clean search term ("Some Game") before searching.
    # show_parsed: show the cleaned search term when it differs from the input.
    #
    # use_color: 1 = coloured output, 0 = plain text.
    # color_label: colour of labels and separators ("Genres:", "|").
    # color_value: colour of the values (genres, price, date, ...).
    # color_title: colour of the game name (the name is always bold).
    # color_text: colour of the description and of messages such as usage, "No results" and errors.
    # color_url: colour of image, screenshot and store links. If your IRC client does not make coloured links clickable, set it to "".
    #   An empty value "" means: no colour for that part.
    #
    # ============================ CONFIG ============================
    
    variable cfg [dict create \
        channels         {#channel} \
        trigger          "!steam" \
        country          "en" \
        lang             "english" \
        timeout          8000 \
        cooldown         5 \
        maxdesc          220 \
        maxalt           3 \
        maxshots         2 \
        \
        use_color        1 \
        color_label      14 \
        color_value      03 \
        color_title      03 \
        color_text       14 \
        color_url        03 \
        \
        show_appid       1 \
        show_genres      1 \
        show_release     1 \
        show_developer   1 \
        show_publisher   0 \
        show_platforms   0 \
        show_price       1 \
        show_discount    1 \
        show_metacritic  1 \
        show_description 1 \
        show_image       1 \
        show_screenshots 0 \
        show_link        1 \
        show_alts        1 \
        \
        parse_release    1 \
        show_parsed      1 \
    ]
    
    # ========================== END OF CONFIG =======================

    variable version "1.6"

    variable lastuse
    array set lastuse {}

    ::http::register https 443 [list ::tls::socket -autoservername true]
    bind pub - [dict get $cfg trigger] ::steam::pub
}

# ---------------------------------------------------------------- helpers

proc ::steam::opt {key} {
    variable cfg
    return [dict get $cfg $key]
}

proc ::steam::fetch {url} {
    if {[catch {::http::geturl $url -timeout [opt timeout] -binary 1} tok]} {
        return -code error $tok
    }
    set status [::http::status $tok]
    set ncode  [::http::ncode $tok]
    set data   [::http::data $tok]
    ::http::cleanup $tok
    if {$status ne "ok" || $ncode != 200} {
        return -code error "HTTP $status $ncode"
    }
    return [encoding convertfrom utf-8 $data]
}

proc ::steam::clean {txt} {
    regsub -all {<[^>]*>} $txt " " txt
    set txt [string map [list \
        "&quot;" "\"" "&amp;" "&" "&lt;" "<" "&gt;" ">" \
        "&#39;" "'" "&nbsp;" " " "\r" " " "\n" " " "\t" " "] $txt]
    regsub -all {\s+} $txt " " txt
    return [string trim $txt]
}

proc ::steam::trunc {txt max} {
    if {[string length $txt] > $max} {
        return "[string trimright [string range $txt 0 [expr {$max - 4}]]]..."
    }
    return $txt
}

# Send a line to the channel. Colours and bold are removed when the channel
# has mode +c (colour blocking), so the message is not rejected.
proc ::steam::say {chan txt} {
    if {[botonchan $chan] && [string match *c* [lindex [getchanmode $chan] 0]]} {
        regsub -all "\003(\[0-9\]{1,2}(,\[0-9\]{1,2})?)?" $txt {} txt
        regsub -all "\002" $txt {} txt
    }
    putserv "PRIVMSG $chan :$txt"
}

# Colour a piece of text. Empty code or use_color 0 returns the text as is.
proc ::steam::col {code txt} {
    if {![opt use_color] || $code eq ""} { return $txt }
    if {[string length $code] == 1} { set code "0$code" }
    return "\003$code$txt\003"
}

# "Label: value", label and value in their own colours.
# Pass colorvalue 0 when the value is already coloured (for example a URL).
proc ::steam::field {label value {colorvalue 1}} {
    set l [col [opt color_label] "$label:"]
    if {$colorvalue} { set value [col [opt color_value] $value] }
    return "$l $value"
}

# Separator between fields on one line.
proc ::steam::sep {} {
    return " [col [opt color_label] |] "
}

# Plain text such as the description and messages.
proc ::steam::text {txt} {
    return [col [opt color_text] $txt]
}

# URLs.
proc ::steam::url {txt} {
    return [col [opt color_url] $txt]
}

proc ::steam::chan_allowed {chan} {
    set list [opt channels]
    if {[llength $list] == 0} { return 1 }
    return [expr {[lsearch -exact [string tolower $list] [string tolower $chan]] >= 0}]
}

# Remove the query string from an image URL
proc ::steam::nostrip {url} {
    return [lindex [split $url ?] 0]
}

# Turn a release-style name (Some.Game.v1.2.3.MULTi5-GROUP) into a search
# term (Some Game). Input with spaces is left alone.
proc ::steam::release_to_title {term} {
    if {[string first " " $term] >= 0 || ![regexp {[._].*[._]} $term]} {
        return $term
    }
    set t $term
    # drop the trailing -GROUP
    regsub -- {-[A-Za-z0-9]+$} $t {} t
    # dots and underscores become spaces
    regsub -all {[._]+} $t " " t
    set plain [string trim $t]
    # cut everything from the first version/tag word onward
    set junk {v\d+|build|update|multi\d*|repack|proper|readnfo|internal|cracked|incl|dlc|gog|linux|macos|x64|x86|iso|rip|retail|preload|hotfix|patch}
    regsub -nocase "\\y(?:$junk)\\y.*\$" $t {} t
    set t [string trim $t]
    if {$t eq ""} { return $plain }
    return $t
}

# ---------------------------------------------------------------- API

proc ::steam::search {term} {
    set q [::http::formatQuery term $term l [opt lang] cc [opt country]]
    set raw [fetch "https://store.steampowered.com/api/storesearch/?$q"]
    set d [::json::json2dict $raw]
    if {![dict exists $d items]} { return {} }
    return [dict get $d items]
}

proc ::steam::details {appid} {
    set q [::http::formatQuery appids $appid l [opt lang] cc [opt country]]
    set raw [fetch "https://store.steampowered.com/api/appdetails?$q"]
    set d [::json::json2dict $raw]
    if {![dict exists $d $appid]} { return {} }
    set entry [dict get $d $appid]
    if {![dict exists $entry success] || ![dict get $entry success]} { return {} }
    return [dict get $entry data]
}

# ---------------------------------------------------------------- bind

proc ::steam::pub {nick uhost hand chan text} {
    variable lastuse

    if {![chan_allowed $chan]} { return 0 }

    set term [string trim $text]
    if {$term eq ""} {
        say $chan [text "Usage: [opt trigger] <game name or App ID>"]
        return 1
    }

    set now [clock seconds]
    if {[info exists lastuse($chan)] && ($now - $lastuse($chan)) < [opt cooldown]} {
        return 1
    }
    set lastuse($chan) $now

    set alts {}
    if {[string is integer -strict $term]} {
        set appid $term
    } else {
        if {[opt parse_release]} {
            set parsed [release_to_title $term]
            if {$parsed ne $term && [opt show_parsed]} {
                say $chan [field "Searching for" $parsed]
            }
            set term $parsed
        }
        if {[catch {search $term} items]} {
            say $chan [text "Steam search failed: $items"]
            return 1
        }
        if {[llength $items] == 0} {
            say $chan [text "No results for '$term'."]
            return 1
        }
        set appid [dict get [lindex $items 0] id]
        foreach it [lrange $items 1 [opt maxalt]] {
            lappend alts "[dict get $it name] ([dict get $it id])"
        }
    }

    if {[catch {details $appid} g]} {
        say $chan [text "Fetching Steam details failed: $g"]
        return 1
    }
    if {[llength $g] == 0} {
        say $chan [text "No details available for App ID $appid."]
        return 1
    }

    # --- line 1: name + optional fields
    set title [col [opt color_title] "\002[dict get $g name]\002"]
    if {[opt show_appid]} { append title " [col [opt color_label] ($appid)]" }
    set parts [list $title]

    if {[opt show_genres] && [dict exists $g genres]} {
        set gn {}
        foreach x [dict get $g genres] { lappend gn [dict get $x description] }
        if {[llength $gn]} { lappend parts [field Genres [join $gn {, }]] }
    }
    if {[opt show_release] && [dict exists $g release_date]} {
        set rd [dict get $g release_date]
        if {[dict exists $rd date] && [dict get $rd date] ne ""} {
            lappend parts [field Release [dict get $rd date]]
        }
    }
    if {[opt show_developer] && [dict exists $g developers] && [llength [dict get $g developers]]} {
        lappend parts [field Developer [join [dict get $g developers] {, }]]
    }
    if {[opt show_publisher] && [dict exists $g publishers] && [llength [dict get $g publishers]]} {
        lappend parts [field Publisher [join [dict get $g publishers] {, }]]
    }
    if {[opt show_platforms] && [dict exists $g platforms]} {
        set pl {}
        dict for {k v} [dict get $g platforms] {
            if {$v} { lappend pl $k }
        }
        if {[llength $pl]} { lappend parts [field Platforms [join $pl {, }]] }
    }
    say $chan [join $parts [sep]]

    # --- line 2: price and score
    set info {}
    if {[opt show_price]} {
        if {[dict exists $g is_free] && [dict get $g is_free]} {
            lappend info [field Price Free]
        } elseif {[dict exists $g price_overview]} {
            set p [dict get $g price_overview]
            set s [dict get $p final_formatted]
            if {[opt show_discount] && [dict exists $p discount_percent] \
                    && [dict get $p discount_percent] > 0} {
                append s " (-[dict get $p discount_percent]%, was [dict get $p initial_formatted])"
            }
            lappend info [field Price $s]
        }
    }
    if {[opt show_metacritic] && [dict exists $g metacritic]} {
        lappend info [field Metacritic [dict get [dict get $g metacritic] score]]
    }
    if {[llength $info]} { say $chan [join $info [sep]] }

    # --- description
    if {[opt show_description] && [dict exists $g short_description]} {
        set desc [clean [dict get $g short_description]]
        if {$desc ne ""} { say $chan [text [trunc $desc [opt maxdesc]]] }
    }

    # --- image and link (URLs are never coloured)
    set links {}
    if {[opt show_image] && [dict exists $g header_image]} {
        lappend links [field Image [url [nostrip [dict get $g header_image]]] 0]
    }
    if {[opt show_link]} {
        lappend links [url "https://store.steampowered.com/app/$appid"]
    }
    if {[llength $links]} { say $chan [join $links [sep]] }

    # --- screenshots
    if {[opt show_screenshots] && [dict exists $g screenshots]} {
        set shots {}
        foreach s [lrange [dict get $g screenshots] 0 [expr {[opt maxshots] - 1}]] {
            if {[dict exists $s path_full]} { lappend shots [url [nostrip [dict get $s path_full]]] }
        }
        if {[llength $shots]} { say $chan [field Screenshots [join $shots [sep]] 0] }
    }

    # --- other search results
    if {[opt show_alts] && [llength $alts]} {
        say $chan [field "Also found" [join $alts {, }]]
    }
    return 1
}

putlog "TeRRaDuDe Steam.tcl v$::steam::version loaded (trigger: [::steam::opt trigger])"
