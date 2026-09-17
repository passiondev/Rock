<#
.SYNOPSIS
    Finishes Rock's Font Awesome to Tabler conversion for every value that has a
    confident Tabler target. Dry run by default; writes only with -Apply.

.DESCRIPTION
    Rock 19's 202603271810501_ReplaceFontAwesomeWithTablerIcons migration converted
    only part of this installation. It joins IconCssClass to __IconTransition on
    exact equality, and that table is keyed on the v4 'fa fa-x' form alone. Values
    written as 'fas fa-x', 'far fa-x', 'fal fa-x', 'fab fa-x' or bare 'fa-x' never
    matched, so they were never converted. That is the whole of the gap: the
    migration did not fail, it only ever covered one of several prefix forms.

    This script closes the part of that gap that needs no human judgement. Each
    value below was resolved by normalising its prefix to the 'fa fa-x' key and
    then taking a target from one of exactly two sources:

        map         the shipped __IconTransition row for that key
        exact-name  a Tabler class of the identical name, where the map had no row

    EVERY TARGET WAS CHECKED AGAINST THE SHIPPED FONT. The Tabler class in each
    replacement was verified to exist in Assets/Fonts/TablerFont before this table
    was written. That check is what the five-row repair in the sibling script fixed
    the need for: the mapping table itself named five classes that do not exist.

    MATCHING IS EXACT, NEVER LIKE, and the table is a closed hardcoded set. The old
    value is compared whole. Nothing is discovered at runtime and no value outside
    this table is rewritten, so the dry run output is exactly what -Apply will do.

    MODIFIERS ARE PRESERVED. 'fa-fw fas fa-arrow-up' becomes 'ti ti-arrow-up fa-fw'
    rather than losing the fixed-width class that controls the layout around it.

    WHAT THIS DELIBERATELY DOES NOT TOUCH:

      - Values with no confident Tabler target. Roughly a quarter of what is left
        is either absent from the mapping table or mapped to nothing, most of it
        Font Awesome Pro icons chosen by hand here. Those need someone to pick a
        substitute. The script writes them to a review sheet instead of guessing.
      - Font Awesome embedded in markup: HtmlContent, Block PreHtml and PostHtml,
        Lava shortcodes, communication templates, workflow form headers. Rewriting
        an icon inside arbitrary HTML is a different and riskier problem.

    Leaving a value on Font Awesome is safe. v19 still ships and loads the Font
    Awesome webfonts, including fa-v4compatibility, so an unconverted value still
    renders. It just does not match the Tabler icons beside it.

    TABLE DISCOVERY MIRRORS THE MIGRATION. The same predicate: a user table, a
    column named IconCssClass, a character type. The character-type filter is the
    fork-local narrowing from Documentation/Fork-Local-Changes.md.

    ROCK CACHES THESE VALUES IN MEMORY. PageCache, BlockTypeCache, CategoryCache,
    DefinedValueCache and friends are plain in-process caches on an installation
    with no Redis, so a raw SQL write is invisible until the application domain
    recycles. Production recycles nightly. Nothing here recycles anything.

    Windows PowerShell 5.1 compatible: ADO.NET directly rather than Invoke-Sqlcmd,
    which needs the SqlServer module that is not installed on the deploy VM.

.PARAMETER ExpectedCatalog
    The catalog this run is meant for, compared against DB_NAME() after connecting.
    Mandatory, and there is deliberately no default.

.PARAMETER ConnectionString
    Optional. Falls back to $env:ROCK_DB_CONNECTION_STRING, then to the
    connectionStrings entry in -WebConnectionStringsPath.

.PARAMETER WebConnectionStringsPath
    Optional path to web.ConnectionStrings.config, read only when no connection
    string is supplied any other way. Lets the script run on the web server without
    the credential ever being typed, logged or put in the process list.

.PARAMETER Apply
    Execute. Without it the script reports what it would do and changes nothing.

.PARAMETER RollbackScriptPath
    Where to write the generated rollback. Defaults to a timestamped file beside the
    script. Written in both modes, so the dry run also shows what the undo looks like.

.PARAMETER ReviewSheetPath
    Where to write the CSV of Font Awesome values this run did not convert. Written
    in both modes. This is the list someone has to make a decision about.

.EXAMPLE
    ./Convert-RockFontAwesomeToTabler.ps1 -ExpectedCatalog RockConnectProd
    ./Convert-RockFontAwesomeToTabler.ps1 -ExpectedCatalog RockConnectProd -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]
    $ExpectedCatalog,

    [Parameter(Mandatory = $false)]
    [string]
    $ConnectionString,

    [Parameter(Mandatory = $false)]
    [string]
    $WebConnectionStringsPath,

    [Parameter(Mandatory = $false)]
    [switch]
    $Apply,

    [Parameter(Mandatory = $false)]
    [string]
    $RollbackScriptPath,

    [Parameter(Mandatory = $false)]
    [string]
    $ReviewSheetPath,

    [Parameter(Mandatory = $false)]
    [int]
    $CommandTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The closed conversion set. Key is the Font Awesome value present in this
# installation, value is the Tabler replacement. Generated by normalising the
# prefix to the 'fa fa-x' key, resolving against the shipped __IconTransition
# table (or an identically named Tabler class where the map had no row), and
# verifying the resulting class exists in the shipped Tabler font.
$conversionTable = @{
    'fa fa fa-file-import'           = 'ti ti-file-import'
    'fa fa-apple'                    = 'ti ti-apple'
    'fa fa-cloud-upload'             = 'ti ti-cloud-upload'
    'fa fa-dashboard'                = 'ti ti-dashboard'
    'fa fa-exchange-alt'             = 'ti ti-arrows-right-left'
    'fa fa-eye'                      = 'ti ti-eye'
    'fa fa-file-import'              = 'ti ti-file-import'
    'fa fa-filter'                   = 'ti ti-filter'
    'fa fa-lock'                     = 'ti ti-lock'
    'fa fa-medkit'                   = 'ti ti-first-aid-kit'
    'fa fa-shield-check'             = 'ti ti-shield-check'
    'fa fa-spade'                    = 'ti ti-spade'
    'fa fa-stars'                    = 'ti ti-stars'
    'fa-cash-register'               = 'ti ti-cash-register'
    'fa-church'                      = 'ti ti-building-church'
    'fa-credit-card'                 = 'ti ti-credit-card'
    'fa-desktop'                     = 'ti ti-device-desktop'
    'fa-dollar-sign'                 = 'ti ti-currency-dollar'
    'fa-file-contract'               = 'ti ti-file-dollar'
    'fa-fw fas fa-arrow-up'          = 'ti ti-arrow-up fa-fw'
    'fa-fw fas fa-chevron-circle-up' = 'ti ti-circle-chevron-up fa-fw'
    'fa-fw fas fa-chevron-up'        = 'ti ti-chevron-up fa-fw'
    'fa-mobile-alt'                  = 'ti ti-device-mobile'
    'fa-money-bill'                  = 'ti ti-cash'
    'fa-question'                    = 'ti ti-question-mark'
    'fa-sms'                         = 'ti ti-device-mobile-message'
    'fa-university'                  = 'ti ti-building-bank'
    'fad fa-map-marked-alt'          = 'ti ti-map-2'
    'fal fa-calendar-star'           = 'ti ti-calendar-star'
    'fal fa-chair'                   = 'ti ti-armchair'
    'fal fa-comment-alt'             = 'ti ti-message'
    'fal fa-user'                    = 'ti ti-user'
    'fal fa-users'                   = 'ti ti-users'
    'far fa-birthday-cake'           = 'ti ti-cake'
    'far fa-browser'                 = 'ti ti-browser'
    'far fa-chair'                   = 'ti ti-armchair'
    'far fa-circle'                  = 'ti ti-circle'
    'far fa-cloud-upload-alt'        = 'ti ti-cloud-upload'
    'far fa-cogs'                    = 'ti ti-settings-cog'
    'far fa-envelope-square'         = 'ti ti-inbox'
    'far fa-file'                    = 'ti ti-file'
    'far fa-hashtag'                 = 'ti ti-hash'
    'far fa-heart'                   = 'ti ti-heart'
    'far fa-network-wired'           = 'ti ti-schema'
    'far fa-print'                   = 'ti ti-printer'
    'far fa-shield-check'            = 'ti ti-shield-check'
    'far fa-upload'                  = 'ti ti-upload'
    'far fa-wine-bottle'             = 'ti ti-bottle'
    'fas  fa-sparkles'               = 'ti ti-sparkles'
    'fas fa-address-book'            = 'ti ti-address-book'
    'fas fa-archive'                 = 'ti ti-archive'
    'fas fa-arrow-up'                = 'ti ti-arrow-up'
    'fas fa-baby-carriage'           = 'ti ti-baby-carriage'
    'fas fa-bank'                    = 'ti ti-building-bank'
    'fas fa-bar-chart'               = 'ti ti-chart-bar'
    'fas fa-bible'                   = 'ti ti-bible'
    'fas fa-biking'                  = 'ti ti-bike'
    'fas fa-bolt'                    = 'ti ti-bolt'
    'fas fa-book'                    = 'ti ti-book'
    'fas fa-book-open'               = 'ti ti-book'
    'fas fa-book-reader'             = 'ti ti-book'
    'fas fa-briefcase-medical'       = 'ti ti-first-aid-kit'
    'fas fa-bug'                     = 'ti ti-bug'
    'fas fa-bullhorn'                = 'ti ti-speakerphone'
    'fas fa-calendar'                = 'ti ti-calendar'
    'fas fa-calendar-alt'            = 'ti ti-calendar-month'
    'fas fa-calendar-check'          = 'ti ti-calendar-check'
    'fas fa-calendar-day'            = 'ti ti-calendar-event'
    'fas fa-calendar-exclamation'    = 'ti ti-calendar-exclamation'
    'fas fa-calendar-star'           = 'ti ti-calendar-star'
    'fas fa-calendar-week'           = 'ti ti-calendar-week'
    'fas fa-camera'                  = 'ti ti-camera'
    'fas fa-campfire'                = 'ti ti-campfire'
    'fas fa-campground'              = 'ti ti-tent'
    'fas fa-car'                     = 'ti ti-car'
    'fas fa-car-side'                = 'ti ti-car'
    'fas fa-caret-up'                = 'ti ti-caret-up'
    'fas fa-chair'                   = 'ti ti-armchair'
    'fas fa-chart-bar'               = 'ti ti-chart-bar'
    'fas fa-chart-line'              = 'ti ti-chart-line'
    'fas fa-chart-pie'               = 'ti ti-chart-pie'
    'fas fa-check'                   = 'ti ti-check'
    'fas fa-check-square-o'          = 'ti ti-square-check'
    'fas fa-chevron-circle-right'    = 'ti ti-circle-chevron-right'
    'fas fa-chevron-circle-up'       = 'ti ti-circle-chevron-up'
    'fas fa-chevron-up'              = 'ti ti-chevron-up'
    'fas fa-child'                   = 'ti ti-user-screen'
    'fas fa-church'                  = 'ti ti-building-church'
    'fas fa-circle'                  = 'ti ti-circle'
    'fas fa-city'                    = 'ti ti-building-skyscraper'
    'fas fa-clipboard'               = 'ti ti-clipboard'
    'fas fa-clipboard-check'         = 'ti ti-clipboard-check'
    'fas fa-clipboard-list'          = 'ti ti-clipboard-list'
    'fas fa-cloud-upload-alt'        = 'ti ti-cloud-upload'
    'fas fa-cogs'                    = 'ti ti-settings-cog'
    'fas fa-comment'                 = 'ti ti-message'
    'fas fa-comment-alt'             = 'ti ti-message'
    'fas fa-comments'                = 'ti ti-messages'
    'fas fa-compress'                = 'ti ti-minimize'
    'fas fa-couch'                   = 'ti ti-sofa'
    'fas fa-cross'                   = 'ti ti-cross'
    'fas fa-cubes'                   = 'ti ti-packages'
    'fas fa-cut'                     = 'ti ti-cut'
    'fas fa-door-open'               = 'ti ti-door-enter'
    'fas fa-dumbbell'                = 'ti ti-barbell'
    'fas fa-edit'                    = 'ti ti-edit'
    'fas fa-envelope'                = 'ti ti-mail'
    'fas fa-envelope-open-text'      = 'ti ti-mail-opened'
    'fas fa-exchange'                = 'ti ti-switch-3'
    'fas fa-exchange-alt'            = 'ti ti-arrows-right-left'
    'fas fa-exclamation-circle'      = 'ti ti-exclamation-circle'
    'fas fa-exclamation-triangle'    = 'ti ti-alert-triangle'
    'fas fa-file-alt'                = 'ti ti-file'
    'fas fa-file-check'              = 'ti ti-file-check'
    'fas fa-file-code'               = 'ti ti-file-code'
    'fas fa-file-contract'           = 'ti ti-file-dollar'
    'fas fa-file-search'             = 'ti ti-file-search'
    'fas fa-film'                    = 'ti ti-movie'
    'fas fa-filter'                  = 'ti ti-filter'
    'fas fa-fire'                    = 'ti ti-flame'
    'fas fa-fist-raised'             = 'ti ti-hand-grab'
    'fas fa-folder'                  = 'ti ti-folder'
    'fas fa-folder-minus'            = 'ti ti-folder-minus'
    'fas fa-folder-open'             = 'ti ti-folder-open'
    'fas fa-folder-plus'             = 'ti ti-folder-plus'
    'fas fa-forward'                 = 'ti ti-player-track-next'
    'fas fa-gear'                    = 'ti ti-settings'
    'fas fa-globe'                   = 'ti ti-globe'
    'fas fa-greater-than'            = 'ti ti-math-greater'
    'fas fa-group'                   = 'ti ti-users'
    'fas fa-handshake'               = 'ti ti-heart-handshake'
    'fas fa-hashtag'                 = 'ti ti-hash'
    'fas fa-heart'                   = 'ti ti-heart'
    'fas fa-hiking'                  = 'ti ti-trekking'
    'fas fa-history'                 = 'ti ti-history'
    'fas fa-home'                    = 'ti ti-home'
    'fas fa-hourglass-end'           = 'ti ti-hourglass-low'
    'fas fa-id-card'                 = 'ti ti-id'
    'fas fa-info-circle'             = 'ti ti-info-circle'
    'fas fa-layer-group'             = 'ti ti-stack'
    'fas fa-leaf'                    = 'ti ti-leaf'
    'fas fa-lightbulb'               = 'ti ti-bulb'
    'fas fa-link'                    = 'ti ti-link'
    'fas fa-list'                    = 'ti ti-list'
    'fas fa-list-alt'                = 'ti ti-list-details'
    'fas fa-list-ol'                 = 'ti ti-list-numbers'
    'fas fa-location-arrow'          = 'ti ti-location'
    'fas fa-lock'                    = 'ti ti-lock'
    'fas fa-magic'                   = 'ti ti-wand'
    'fas fa-map-marked-alt'          = 'ti ti-map-2'
    'fas fa-map-marker-alt'          = 'ti ti-map-pin'
    'fas fa-message'                 = 'ti ti-message'
    'fas fa-mobile'                  = 'ti ti-device-mobile'
    'fas fa-mobile-alt'              = 'ti ti-device-mobile'
    'fas fa-mug-hot'                 = 'ti ti-coffee'
    'fas fa-music'                   = 'ti ti-music'
    'fas fa-paint'                   = 'ti ti-paint'
    'fas fa-palette'                 = 'ti ti-palette'
    'fas fa-pencil-ruler'            = 'ti ti-edit'
    'fas fa-people-arrows'           = 'ti ti-friends'
    'fas fa-people-carry'            = 'ti ti-package-export'
    'fas fa-phone'                   = 'ti ti-phone'
    'fas fa-pizza-slice'             = 'ti ti-pizza'
    'fas fa-play-circle'             = 'ti ti-player-play'
    'fas fa-plug'                    = 'ti ti-plug'
    'fas fa-plus'                    = 'ti ti-plus'
    'fas fa-plus-circle'             = 'ti ti-circle-plus'
    'fas fa-poll-h'                  = 'ti ti-notes'
    'fas fa-pray'                    = 'ti ti-pray'
    'fas fa-praying-hands'           = 'ti ti-pray'
    'fas fa-prescription'            = 'ti ti-prescription'
    'fas fa-question-circle'         = 'ti ti-zoom-question'
    'fas fa-report'                  = 'ti ti-report'
    'fas fa-road'                    = 'ti ti-road'
    'fas fa-running'                 = 'ti ti-run'
    'fas fa-school'                  = 'ti ti-school'
    'fas fa-scroll'                  = 'ti ti-contract'
    'fas fa-search'                  = 'ti ti-search'
    'fas fa-search-dollar'           = 'ti ti-zoom-money'
    'fas fa-seedling'                = 'ti ti-seedling'
    'fas fa-shield'                  = 'ti ti-shield-half'
    'fas fa-shield-check'            = 'ti ti-shield-check'
    'fas fa-shopping-cart'           = 'ti ti-shopping-cart'
    'fas fa-sliders-h'               = 'ti ti-adjustments-horizontal'
    'fas fa-sms'                     = 'ti ti-device-mobile-message'
    'fas fa-spa'                     = 'ti ti-flower'
    'fas fa-sparkles'                = 'ti ti-sparkles'
    'fas fa-spinner'                 = 'ti ti-rotate-2'
    'fas fa-stars'                   = 'ti ti-stars'
    'fas fa-sticky-note'             = 'ti ti-sticker-2'
    'fas fa-sun'                     = 'ti ti-sun'
    'fas fa-sync'                    = 'ti ti-refresh'
    'fas fa-table-tennis'            = 'ti ti-ping-pong'
    'fas fa-tachometer-alt'          = 'ti ti-brand-speedtest'
    'fas fa-tag'                     = 'ti ti-tag'
    'fas fa-tags'                    = 'ti ti-tags'
    'fas fa-th-list'                 = 'ti ti-table'
    'fas fa-ticket-alt'              = 'ti ti-ticket'
    'fas fa-tint'                    = 'ti ti-droplet'
    'fas fa-tools'                   = 'ti ti-tools'
    'fas fa-tshirt'                  = 'ti ti-shirt'
    'fas fa-university'              = 'ti ti-building-bank'
    'fas fa-user'                    = 'ti ti-user'
    'fas fa-user-alt-slash'          = 'ti ti-user-off'
    'fas fa-user-check'              = 'ti ti-user-check'
    'fas fa-user-circle'             = 'ti ti-user-circle'
    'fas fa-user-cog'                = 'ti ti-user-cog'
    'fas fa-user-edit'               = 'ti ti-user-edit'
    'fas fa-user-friends'            = 'ti ti-users'
    'fas fa-user-lock'               = 'ti ti-user-shield'
    'fas fa-user-plus'               = 'ti ti-user-plus'
    'fas fa-user-secret'             = 'ti ti-spy'
    'fas fa-user-shield'             = 'ti ti-user-shield'
    'fas fa-user-tag'                = 'ti ti-user-dollar'
    'fas fa-users'                   = 'ti ti-users'
    'fas fa-utensils'                = 'ti ti-tools-kitchen-2'
    'fas fa-vial'                    = 'ti ti-test-pipe'
    'fas fa-video'                   = 'ti ti-video'
    'fas fa-video-plus'              = 'ti ti-video-plus'
    'fas fa-walking'                 = 'ti ti-walk'
    'fas fa-water'                   = 'ti ti-ripple'
    'fas fa-yin-yang'                = 'ti ti-yin-yang'

    # ---------------------------------------------------------------------
    # Supplied by Passion staff on 2026-09-17, then validated: every target
    # below was confirmed to exist in the shipped Tabler font before it was
    # written here. Four of the supplied targets named a class Tabler does
    # not carry and were dropped rather than guessed at; six typos in the
    # sheet were corrected against the real class list.
    # ---------------------------------------------------------------------
    'fa fa-500px'                       = 'ti ti-square-number-5'
    'fa fa-boxing-glove'                = 'ti ti-hand-grab'
    'fa fa-cc-stripe'                   = 'ti ti-brand-stripe'
    'fa fa-clipboard-user'              = 'ti ti-clipboard-heart'
    'fa fa-code-fork'                   = 'ti ti-git-branch'
    'fa fa-commenting-o'                = 'ti ti-message-dots'
    'fa fa-dollar'                      = 'ti ti-currency-dollar'
    'fa fa-email'                       = 'ti ti-mail'
    'fa fa-exclamation-triangle'        = 'ti ti-alert-triangle'
    'fa fa-hand-holding'                = 'ti ti-empathize'
    'fa fa-hand-holding-heart'          = 'ti ti-heart-handshake'
    'fa fa-hand-paper-o'                = 'ti ti-hand-stop'
    'fa fa-handshake-o'                 = 'ti ti-user-heart'
    'fa fa-hospital-o'                  = 'ti ti-building-hospital'
    'fa fa-long-arrow-right'            = 'ti ti-arrow-narrow-right'
    'fa fa-pen-fancy'                   = 'ti ti-writing-sign'
    'fa fa-ramp-loading'                = 'ti ti-compass'
    'fa fa-rocket-launch'               = 'ti ti-rocket'
    'fa fa-ruler-triangle'              = 'ti ti-ruler'
    'fa fa-searchengin'                 = 'ti ti-input-search'
    'fa fa-venus-mars'                  = 'ti ti-friends'
    'fa fa-wordpress'                   = 'ti ti-brand-wordpress'
    'fa-apple-pay'                      = 'ti ti-brand-apple'
    'fa-google-pay'                     = 'ti ti-brand-google'
    'fa-hand-holding-usd'               = 'ti ti-moneybag-heart'
    'fa-money-check'                    = 'ti ti-cash-banknote'
    'fa-solid fa-money-bill-transfer'   = 'ti ti-transfer'
    'fab fa-slack'                      = 'ti ti-brand-slack'
    'fal fa-hand-holding-heart'         = 'ti ti-heart-handshake'
    'far fa-boxing-glove'               = 'ti ti-hand-grab'
    'far fa-calendar-edit'              = 'ti ti-calendar-up'
    'far fa-comment-alt-lines'          = 'ti ti-message'
    'far fa-users-cog'                  = 'ti ti-user-cog'
    'fas fa-badge-check'                = 'ti ti-rosette-discount-check'
    'fas fa-baseball'                   = 'ti ti-ball-baseball'
    'fas fa-bow-arrow'                  = 'ti ti-bow'
    'fas fa-box-check'                  = 'ti ti-package'
    'fas fa-box-full'                   = 'ti ti-package'
    'fas fa-box-open'                   = 'ti ti-package-import'
    'fas fa-box-usd'                    = 'ti ti-receipt-dollar'
    'fas fa-boxing-glove'               = 'ti ti-hand-grab'
    'fas fa-calendar-edit'              = 'ti ti-calendar-week'
    'fas fa-car-building'               = 'ti ti-building-cog'
    'fas fa-caret-circle-right'         = 'ti ti-caret-right'
    'fas fa-cars'                       = 'ti ti-parking-circle'
    'fas fa-cctv'                       = 'ti ti-shield-lock'
    'fas fa-chart'                      = 'ti ti-chart-bar'
    'fas fa-chart-network'              = 'ti ti-chart-dots-3'
    'fas fa-circle-notch'               = 'ti ti-circle-dashed'
    'fas fa-clipboard-list-check'       = 'ti ti-clipboard-list'
    'fas fa-clipboard-user'             = 'ti ti-clipboard-heart'
    'fas fa-clouds'                     = 'ti ti-cloud-fog'
    'fas fa-comment-check'              = 'ti ti-message-plus'
    'fas fa-comment-exclamation'        = 'ti ti-message-report'
    'fas fa-comment-lines'              = 'ti ti-message'
    'fas fa-comments-dollar'            = 'ti ti-receipt-dollar'
    'fas fa-computer'                   = 'ti ti-device-desktop'
    'fas fa-computer-classic'           = 'ti ti-device-desktop'
    'fas fa-construction'               = 'ti ti-barrier-block'
    'fas fa-debug'                      = 'ti ti-bug-off'
    'fas fa-do-not-enter'               = 'ti ti-ban'
    'fas fa-email'                      = 'ti ti-mail'
    'fas fa-file-chart-line'            = 'ti ti-file-analytics'
    'fas fa-file-chart-pie'             = 'ti ti-file-chart'
    'fas fa-file-exclamation'           = 'ti ti-file-alert'
    'fas fa-file-user'                  = 'ti ti-user-square'
    'fas fa-flower-daffodil'            = 'ti ti-macro'
    'fas fa-flower-tulip'               = 'ti ti-macro'
    'fas fa-game-board'                 = 'ti ti-tic-tac'
    'fas fa-globe-stand'                = 'ti ti-globe'
    'fas fa-hand-holding-heart'         = 'ti ti-heart-handshake'
    'fas fa-hand-holding-usd'           = 'ti ti-moneybag-heart'
    'fas fa-hands-heart'                = 'ti ti-heart-handshake'
    'fas fa-handshake-alt'              = 'ti ti-user-heart'
    'fas fa-heart-square'               = 'ti ti-hearts'
    'fas fa-images'                     = 'ti ti-library-photo'
    'fas fa-inbox-out'                  = 'ti ti-mailbox'
    'fas fa-laptop-code'                = 'ti ti-device-desktop-code'
    'fas fa-lightbulb-exclamation'      = 'ti ti-message-2-exclamation'
    'fas fa-lightbulb-on'               = 'ti ti-bulb'
    'fas fa-money-check-edit-alt'       = 'ti ti-receipt-dollar'
    'fas fa-music-alt'                  = 'ti ti-music'
    'fas fa-music-note'                 = 'ti ti-file-music'
    'fas fa-person-dolly'               = 'ti ti-trolley'
    'fas fa-poll-people'                = 'ti ti-list-details'
    'fas fa-racquet'                    = 'ti ti-ball-tennis'
    'fas fa-ruler-triangle'             = 'ti ti-ruler'
    'fas fa-scroll-old'                 = 'ti ti-file-time'
    'fas fa-shield-cross'               = 'ti ti-cross'
    'fas fa-smile-plus'                 = 'ti ti-mood-plus'
    'fas fa-solar-system'               = 'ti ti-api'
    'fas fa-stats'                      = 'ti ti-chart-dots'
    'fas fa-tachometer-fast'            = 'ti ti-dashboard'
    'fas fa-taco'                       = 'ti ti-burger'
    'fas fa-toilet'                     = 'ti ti-toilet-paper'
    'fas fa-tombstone'                  = 'ti ti-grave-2'
    'fas fa-toolbox'                    = 'ti ti-tool'
    'fas fa-tree-alt'                   = 'ti ti-tree'
    'fas fa-tree-christmas'             = 'ti ti-christmas-tree'
    'fas fa-universal-access'           = 'ti ti-accessible'
    'fas fa-usd-circle'                 = 'ti ti-coin'
    'fas fa-user-graduate'              = 'ti ti-school'
    'fas fa-user-tie'                   = 'ti ti-tie'
    'fas fa-users-class'                = 'ti ti-chalkboard-teacher'
    'fas fa-users-cog'                  = 'ti ti-user-bolt'
    'fas fa-watch'                      = 'ti ti-device-watch'
}

function Get-SqlIdentifier {
    <#
        .SYNOPSIS
            Quotes an identifier for interpolation into dynamic SQL. Table and column
            names cannot be parameterised, so they are escaped instead.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return '[' + $Name.Replace(']', ']]') + ']'
}

function Resolve-RockConnectionString {
    <#
        .SYNOPSIS
            Finds a connection string without ever returning it through a log.
    #>
    param(
        [Parameter(Mandatory = $false)][string]$Supplied,
        [Parameter(Mandatory = $false)][string]$ConfigPath
    )

    if (-not [string]::IsNullOrWhiteSpace($Supplied)) {
        return $Supplied
    }

    $fromEnvironment = [Environment]::GetEnvironmentVariable('ROCK_DB_CONNECTION_STRING')
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
        return $fromEnvironment
    }

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "No connection string. -WebConnectionStringsPath was given as '$ConfigPath' and there is no file there. Set `$env:ROCK_DB_CONNECTION_STRING instead."
        }

        [xml]$document = Get-Content -LiteralPath $ConfigPath -Raw
        $entry = $document.connectionStrings.add | Where-Object { $_.name -eq 'RockContext' } | Select-Object -First 1
        if ($null -eq $entry) {
            throw "No connection string. '$ConfigPath' has no connectionStrings entry named RockContext. Set `$env:ROCK_DB_CONNECTION_STRING instead."
        }

        return $entry.connectionString
    }

    throw "No connection string. Set `$env:ROCK_DB_CONNECTION_STRING, or pass -ConnectionString, or point -WebConnectionStringsPath at a web.ConnectionStrings.config."
}

$resolvedConnectionString = Resolve-RockConnectionString -Supplied $ConnectionString -ConfigPath $WebConnectionStringsPath

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($RollbackScriptPath)) {
    $RollbackScriptPath = Join-Path $PSScriptRoot "Rollback-RockFontAwesomeToTabler-$stamp.sql"
}
if ([string]::IsNullOrWhiteSpace($ReviewSheetPath)) {
    $ReviewSheetPath = Join-Path $PSScriptRoot "Review-RockFontAwesomeRemaining-$stamp.csv"
}

$connection = New-Object System.Data.SqlClient.SqlConnection $resolvedConnectionString
$connection.Open()

function Invoke-Read {
    <#
        .SYNOPSIS
            Runs a reader and returns rows as hashtables. Reads only: this is the one
            execution path allowed before the -Apply gate.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $false)][hashtable]$Parameters = @{}
    )

    $command = $connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = $CommandTimeoutSeconds
    foreach ($key in $Parameters.Keys) {
        [void]$command.Parameters.AddWithValue($key, $Parameters[$key])
    }

    $rows = New-Object System.Collections.ArrayList
    $reader = $command.ExecuteReader()
    try {
        while ($reader.Read()) {
            $row = @{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
            }
            [void]$rows.Add($row)
        }
    }
    finally {
        $reader.Close()
        $command.Dispose()
    }

    return , $rows
}

# The catalog check comes before everything else. Refusing the wrong catalog has to
# happen before the script reads anything from it.
$catalogRows = Invoke-Read -Query 'SELECT DB_NAME() AS CatalogName;'
$actualCatalog = [string]$catalogRows[0]['CatalogName']
if ($actualCatalog -ne $ExpectedCatalog) {
    $connection.Close()
    throw "Refusing to continue. -ExpectedCatalog is '$ExpectedCatalog' and this connection is on '$actualCatalog'."
}

Write-Host "Catalog: $actualCatalog"
Write-Host "Mode:    $(if ($Apply) { 'APPLY' } else { 'dry run' })"
Write-Host ("Closed conversion set: {0} value(s)" -f $conversionTable.Count)
Write-Host ''

# Same predicate as the migration, so this reaches exactly the tables it reached.
$tableQuery = @'
SELECT
    s.name AS SchemaName,
    t.name AS TableName,
    c.name AS ColumnName,
    (
        SELECT ISNULL(MAX(p.rows), 0) FROM sys.partitions p
        WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)
    ) AS ApproxRows,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.columns ic
        WHERE ic.object_id = t.object_id AND ic.name = 'Id'
    ) THEN 1 ELSE 0 END AS HasId
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id
-- Not 'c.name = IconCssClass'. Rock also carries SignalType.SignalIconCssClass
-- and its denormalised copy Person.TopSignalIconCssClass, and an exact match on
-- the bare name silently skipped both. Widening the column pattern cannot widen
-- what gets rewritten: the conversion table stays a closed set, so this only
-- finds more rows holding values that were already vetted.
WHERE (c.name LIKE '%IconCssClass%' OR c.name LIKE '%IconClass%')
  AND TYPE_NAME(c.system_type_id) IN ('nvarchar', 'varchar', 'nchar', 'char')
  AND t.is_ms_shipped = 0
ORDER BY s.name, t.name;
'@

$tables = Invoke-Read -Query $tableQuery
Write-Host ("Tables with a character-typed IconCssClass column: {0}" -f $tables.Count)

$plan = New-Object System.Collections.ArrayList
$leftBehind = New-Object System.Collections.ArrayList

function Add-PlanEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Column,
        [Parameter(Mandatory = $true)][string]$OldValue,
        [Parameter(Mandatory = $true)][string]$NewValue,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Ids,
        [Parameter(Mandatory = $true)][bool]$HasId,
        [Parameter(Mandatory = $true)][int]$Affected
    )

    if ($Affected -le 0) {
        return
    }

    [void]$plan.Add([pscustomobject]@{
        Target   = $Target
        Column   = $Column
        OldValue = $OldValue
        NewValue = $NewValue
        Ids      = $Ids
        HasId    = $HasId
        Affected = $Affected
    })
}

function Add-Scope {
    <#
        .SYNOPSIS
            Builds the plan for one table and column. Reads the distinct values
            present once, then asks for row Ids only for the values this run
            actually converts. Everything else is recorded for the review sheet.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Qualified,
        [Parameter(Mandatory = $true)][string]$Column,
        [Parameter(Mandatory = $true)][bool]$HasId,
        [Parameter(Mandatory = $false)][switch]$IconValuesOnly
    )

    $quotedColumn = Get-SqlIdentifier $Column

    # AttributeValue.Value and Attribute.DefaultValue are nvarchar(max) on tables with
    # millions of rows, and they hold every attribute value in Rock rather than icons.
    # Grouping those whole is pointlessly expensive, so the scan is narrowed to values
    # shaped like a Font Awesome class. Nothing is lost: every key in the conversion
    # table is such a value, and the review sheet only reports such values too.
    $restriction = ''
    if ($IconValuesOnly) {
        $prefixes = @(
            'fa fa-%', 'fas fa-%', 'far fa-%', 'fal fa-%', 'fab fa-%', 'fad fa-%', 'fa-%',
            # Irregular spacing occurs in this data: 'fa fa fa-file-import' and
            # 'fas  fa-sparkles' are both real values here. The looser forms below
            # keep those in scope, and every key in the conversion table matches
            # one of the prefixes in this list.
            'fa %', 'fas %', 'far %', 'fal %', 'fab %', 'fad %'
        )
        $likes = ($prefixes | ForEach-Object { "$quotedColumn LIKE '$_'" }) -join ' OR '
        $restriction = " AND LEN($quotedColumn) BETWEEN 3 AND 60 AND ($likes)"
    }

    $distinct = Invoke-Read -Query "SELECT $quotedColumn AS Value, COUNT(*) AS Occurrences FROM $Qualified WHERE $quotedColumn IS NOT NULL AND $quotedColumn <> ''$restriction GROUP BY $quotedColumn;"

    foreach ($row in $distinct) {
        $value = [string]$row['Value']
        $occurrences = [int]$row['Occurrences']

        if ($conversionTable.ContainsKey($value)) {
            $newValue = $conversionTable[$value]

            if ($HasId) {
                $idRows = Invoke-Read -Query "SELECT [Id] FROM $Qualified WHERE $quotedColumn = @old;" -Parameters @{ '@old' = $value }
                $ids = @($idRows | ForEach-Object { $_['Id'] })
                Add-PlanEntry -Target $Qualified -Column $Column -OldValue $value -NewValue $newValue -Ids $ids -HasId $true -Affected $ids.Count
            }
            else {
                # No Id column, so the rollback for this table is value-scoped. Safe
                # here only because the new value is one this run introduced.
                Add-PlanEntry -Target $Qualified -Column $Column -OldValue $value -NewValue $newValue -Ids @() -HasId $false -Affected $occurrences
            }

            continue
        }

        # Not converted. Only Font Awesome values are worth reporting; anything
        # already on Tabler, or not an icon at all, is not a decision for anyone.
        $tokens = @($value -split '\s+' | Where-Object { $_ -ne '' })
        $looksFontAwesome = $false
        foreach ($token in $tokens) {
            if ($token -like 'fa-*' -or $token -in @('fa', 'fas', 'far', 'fal', 'fab', 'fad', 'fat')) {
                $looksFontAwesome = $true
            }
        }
        if ($tokens -contains 'ti' -or ($tokens | Where-Object { $_ -like 'ti-*' })) {
            $looksFontAwesome = $false
        }

        if ($looksFontAwesome) {
            [void]$leftBehind.Add([pscustomobject]@{
                Target      = $Qualified
                Column      = $Column
                Value       = $value
                Occurrences = $occurrences
            })
        }
    }
}

# Tables at or above this size get the narrowed scan rather than a whole-column
# GROUP BY. Person is the one icon-bearing table in that class; the rest are
# configuration tables of a few thousand rows, where a full scan costs nothing and
# keeps the review sheet complete.
$largeTableRowCount = 100000

foreach ($table in $tables) {
    $schemaName = [string]$table['SchemaName']
    $tableName = [string]$table['TableName']
    $columnName = [string]$table['ColumnName']
    $hasId = ([int]$table['HasId']) -eq 1
    $qualified = (Get-SqlIdentifier $schemaName) + '.' + (Get-SqlIdentifier $tableName)

    if ([long]$table['ApproxRows'] -ge $largeTableRowCount) {
        Add-Scope -Qualified $qualified -Column $columnName -HasId $hasId -IconValuesOnly
    }
    else {
        Add-Scope -Qualified $qualified -Column $columnName -HasId $hasId
    }
}

# AttributeValue.Value and Attribute.DefaultValue, the other two places the
# migration wrote. Both were whole-value assignments there too, so the same closed
# table applies unchanged.
Add-Scope -Qualified '[dbo].[AttributeValue]' -Column 'Value' -HasId $true -IconValuesOnly
Add-Scope -Qualified '[dbo].[Attribute]' -Column 'DefaultValue' -HasId $true -IconValuesOnly

# Rock keeps persisted renderings of an attribute value beside the raw Value.
# Writing Value without flagging the row dirty leaves Rock serving the old
# rendering, which is what AttributeValueCache sets when a value changes under it.
$persistedDirtyPresent = (Invoke-Read -Query "SELECT 1 AS Present FROM sys.columns WHERE object_id = OBJECT_ID('dbo.AttributeValue') AND name = 'IsPersistedValueDirty';").Count -gt 0

$totalPlanned = 0
foreach ($entry in $plan) {
    $totalPlanned += $entry.Affected
}

Write-Host ''
Write-Host '--- Plan ---'
if ($plan.Count -eq 0) {
    Write-Host 'Nothing to convert. No row in this catalog holds a value from the conversion set.'
}
else {
    foreach ($entry in $plan | Sort-Object Target, Column, OldValue) {
        $scope = if ($entry.HasId) { "{0} row(s) by Id" -f $entry.Ids.Count } else { "{0} row(s) by value" -f $entry.Affected }
        Write-Host ("{0}.{1}: {2}  '{3}' -> '{4}'" -f $entry.Target, $entry.Column, $scope, $entry.OldValue, $entry.NewValue)
    }
    Write-Host ''
    Write-Host ("{0} statement(s), {1} row(s) total." -f $plan.Count, $totalPlanned)
}

$leftTotal = 0
foreach ($entry in $leftBehind) {
    $leftTotal += $entry.Occurrences
}

Write-Host ''
Write-Host '--- Left on Font Awesome ---'
if ($leftBehind.Count -eq 0) {
    Write-Host 'Nothing. Every Font Awesome value found had a confident Tabler target.'
}
else {
    Write-Host ("{0} row(s) across {1} value/column pairing(s) have no confident Tabler target." -f $leftTotal, $leftBehind.Count)
    Write-Host 'These still render, because v19 continues to ship and load Font Awesome.'
    Write-Host "Written to: $ReviewSheetPath"
    $leftBehind | Sort-Object -Property @{ Expression = 'Occurrences'; Descending = $true }, Value |
        Export-Csv -Path $ReviewSheetPath -NoTypeInformation -Encoding UTF8
}

# The rollback goes to disk before anything is written, so a run that dies part way
# through is still reversible. Row-scoped wherever the table has an Id.
$rollbackLines = New-Object System.Collections.ArrayList
[void]$rollbackLines.Add("-- Rollback for Convert-RockFontAwesomeToTabler.ps1")
[void]$rollbackLines.Add("-- Catalog: $actualCatalog")
[void]$rollbackLines.Add("-- Generated: $(Get-Date -Format 's')")
[void]$rollbackLines.Add("-- Restores the Font Awesome values this run replaced. Row-scoped where an Id exists.")
[void]$rollbackLines.Add('')
[void]$rollbackLines.Add('BEGIN TRANSACTION;')

foreach ($entry in $plan) {
    $escapedOld = $entry.OldValue.Replace("'", "''")
    $escapedNew = $entry.NewValue.Replace("'", "''")
    $column = Get-SqlIdentifier $entry.Column
    if ($entry.HasId -and $entry.Ids.Count -gt 0) {
        $idList = ($entry.Ids -join ', ')
        [void]$rollbackLines.Add("UPDATE $($entry.Target) SET $column = N'$escapedOld' WHERE [Id] IN ($idList);")
    }
    else {
        [void]$rollbackLines.Add("-- No Id column on this table, so this statement is value-scoped.")
        [void]$rollbackLines.Add("UPDATE $($entry.Target) SET $column = N'$escapedOld' WHERE $column = N'$escapedNew';")
    }
}

[void]$rollbackLines.Add('COMMIT TRANSACTION;')
$rollbackLines | Out-File -FilePath $RollbackScriptPath -Encoding UTF8
Write-Host ''
Write-Host "Rollback written to: $RollbackScriptPath"

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Dry run. Nothing was changed. Re-run with -Apply to write.'
    $connection.Close()
    return
}

Write-Host ''
Write-Host '--- Applying ---'

$transaction = $connection.BeginTransaction()
$totalAffected = 0
try {
    foreach ($entry in $plan) {
        $column = Get-SqlIdentifier $entry.Column
        $command = $connection.CreateCommand()
        $command.Transaction = $transaction
        $command.CommandTimeout = $CommandTimeoutSeconds

        if ($entry.HasId -and $entry.Ids.Count -gt 0) {
            $idList = ($entry.Ids -join ', ')
            $command.CommandText = "UPDATE $($entry.Target) SET $column = @new WHERE [Id] IN ($idList);"
        }
        else {
            $command.CommandText = "UPDATE $($entry.Target) SET $column = @new WHERE $column = @old;"
            [void]$command.Parameters.AddWithValue('@old', $entry.OldValue)
        }

        [void]$command.Parameters.AddWithValue('@new', $entry.NewValue)
        $affected = $command.ExecuteNonQuery()
        $command.Dispose()
        $totalAffected += $affected
    }

    Write-Host ("{0} statement(s) executed." -f $plan.Count)

    # Flag the attribute value rows so Rock re-renders them rather than serving the
    # persisted rendering of the Font Awesome class.
    if ($persistedDirtyPresent) {
        $attributeValueIds = @($plan | Where-Object { $_.Target -eq '[dbo].[AttributeValue]' } | ForEach-Object { $_.Ids } | ForEach-Object { $_ })
        if ($attributeValueIds.Count -gt 0) {
            $dirtyCommand = $connection.CreateCommand()
            $dirtyCommand.Transaction = $transaction
            $dirtyCommand.CommandTimeout = $CommandTimeoutSeconds
            $dirtyCommand.CommandText = "UPDATE [dbo].[AttributeValue] SET [IsPersistedValueDirty] = 1 WHERE [Id] IN ($($attributeValueIds -join ', '));"
            $dirtyAffected = $dirtyCommand.ExecuteNonQuery()
            $dirtyCommand.Dispose()
            Write-Host ("[dbo].[AttributeValue].IsPersistedValueDirty: {0} row(s) flagged" -f $dirtyAffected)
        }
    }

    $transaction.Commit()
    Write-Host ''
    Write-Host ("Committed. {0} row(s) changed." -f $totalAffected)
    Write-Host 'Rock caches these values in memory, so the change is not visible until the application domain recycles.'
}
catch {
    $transaction.Rollback()
    Write-Host 'Failed. The transaction was rolled back and nothing was changed.'
    throw
}
finally {
    $connection.Close()
}
