local _ = require("gettext")
return {
    name = "supersync",
    fullname = _("Super Sync"), 
    description = _([[Sync your complete reading metadata (annotations, bookmarks, reading progress, settings) across devices using your existing cloud storage. Unlike the built-in KOReader sync that only syncs reading position, Super Sync backs up your entire .sdr metadata folders to your cloud storage of choice.]]),
}