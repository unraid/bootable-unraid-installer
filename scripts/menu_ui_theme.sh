#!/bin/bash
# Shared whiptail/Newt theme for every installer menu.

configure_whiptail_theme() {
    [[ "${ui_backend:-}" == "whiptail" ]] || return 0
    # Theme hooks are kept here so the Newt colour policy has one update point.
    # The default palette remains active until compact-button support is available.
}
