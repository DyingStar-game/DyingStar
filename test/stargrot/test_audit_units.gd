extends Node
## Run the existing GUT suites in the offline scene, without a second framework.

var _gut


func _ready() -> void:
    _gut = load("res://addons/gut/gut.gd").new()
    add_child(_gut)
    _gut.log_level = 0
    for path in ["res://test/unit/test_stargrot_seams.gd",
            "res://test/unit/test_stargrot_contract.gd",
            "res://test/unit/test_stargrot_authoring.gd",
            "res://test/unit/test_stargrot_sites.gd",
            "res://test/unit/test_stargrot_v8.gd",
            "res://test/unit/test_stargrot_v9.gd",
            "res://test/unit/test_stargrot_portal.gd",
            "res://test/unit/test_stargrot_assets.gd",
            "res://test/unit/test_stargrot_input.gd",
            "res://test/unit/test_stargrot_scatter.gd",
            "res://test/unit/test_stargrot_develop.gd",
            "res://test/unit/test_stargrot_placement_ui.gd",
            "res://test/unit/test_god_mode.gd", "res://test/unit/test_surface_catch.gd",
            "res://test/unit/test_railway_track.gd",
            "res://test/unit/test_chunk_residency.gd", "res://test/unit/test_chunk_queues.gd"]:
        _gut.add_script(path)
    # Upstream contracts touched by the integration and the Windows guard shared with the game.
    for path in ["res://test/unit/test_export_docs.gd", "res://test/unit/test_quit_leaves_voice.gd",
            "res://test/unit/test_voice_system_libraries.gd", "res://test/unit/test_npc_spawn_role.gd",
            "res://test/unit/test_carry_placement.gd", "res://test/unit/test_vehicle_terminal.gd"]:
        _gut.add_script(path)
    _gut.end_run.connect(_finish)
    _gut.test_scripts.call_deferred()


func _finish() -> void:
    var totals: Dictionary = _gut.get_summary().get_totals()
    var file := FileAccess.open("res://test/stargrot/audit-unit-results.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(totals, "  "))
    file.close()
    print("STARGROT AUDIT UNITS ", totals)
    get_tree().quit(0 if totals.tests > 0 and totals.failing == 0 and totals.errors == 0 else 1)
