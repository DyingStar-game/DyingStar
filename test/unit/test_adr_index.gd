extends GutTest
## The architecture decision records stay usable: every ADR is listed in the index, says whether it
## binds, and still points at code that exists. An ADR naming a file that moved sends the next
## contributor, or agent, to the wrong place; one missing from the index is never read.
##
## Also checks that Claude Code reads AGENTS.md: it skips AGENTS.md when a CLAUDE.md exists, so the
## project's CLAUDE.md must import it.

const ADR_DIR : String = "res://docs/adr"
const INDEX : String = "res://docs/adr/README.md"
const STATUSES : Array[String] = ["Accepted", "Proposed", "Superseded"]

var _adr_file := RegEx.create_from_string("^\\d{4}-[a-z0-9-]+\\.md$")
var _index_link := RegEx.create_from_string("\\]\\((\\d{4}-[a-z0-9-]+\\.md)\\)")
var _status := RegEx.create_from_string("^- \\*\\*Status:\\*\\* (\\w+)")
var _quoted := RegEx.create_from_string("`([^`]+)`")


func test_every_adr_is_in_the_index_and_every_entry_exists() -> void:
	var files : PackedStringArray = adr_files()
	assert_gt(files.size(), 0, "no ADR found in " + ADR_DIR)
	var listed : PackedStringArray = []
	for found: RegExMatch in _index_link.search_all(FileAccess.get_file_as_string(INDEX)):
		listed.append(found.get_string(1))
	for file: String in files:
		assert_true(file in listed, "%s is not listed in %s" % [file, INDEX])
	for file: String in listed:
		assert_true(file in files, "%s lists %s, which does not exist" % [INDEX, file])


func test_every_adr_has_a_status() -> void:
	for file: String in adr_files():
		var status : String = status_of(FileAccess.get_file_as_string(ADR_DIR.path_join(file)))
		assert_true(status in STATUSES, "%s: status '%s', expected one of %s" % [file, status, STATUSES])


func test_the_code_an_adr_names_still_exists() -> void:
	var missing : PackedStringArray = []
	for file: String in adr_files():
		for path: String in code_paths(FileAccess.get_file_as_string(ADR_DIR.path_join(file))):
			if not _exists("res://" + path):
				missing.append("%s: %s" % [file, path])
	assert_eq(missing.size(), 0, "ADRs naming files that no longer exist:\n" + "\n".join(missing))


func test_claude_code_reads_agents_md() -> void:
	assert_true(FileAccess.file_exists("res://AGENTS.md"), "AGENTS.md is missing")
	assert_string_contains(FileAccess.get_file_as_string("res://CLAUDE.md"), "@AGENTS.md")


func test_the_rules_read_the_template_format() -> void:
	var src := "\n".join([
		"# 0001. Do it", "- **Status:** Accepted", "## Context", "See `not/a/path.gd` here.",
		"## In the code", "- `scenes/a.gd`: the thing", "- `scenes/native/*.cs` and `docs/`: more",
		"## Enforced by", "- `test/unit/test_a.gd`",
	])
	assert_eq(status_of(src), "Accepted")
	assert_eq(code_paths(src), PackedStringArray(["scenes/a.gd", "scenes/native/*.cs", "docs/"]))


## The ADR files of [constant ADR_DIR] (the index and the template are not ADRs).
func adr_files() -> PackedStringArray:
	var out : PackedStringArray = []
	for file: String in DirAccess.get_files_at(ADR_DIR):
		if _adr_file.search(file) != null:
			out.append(file)
	return out


## The word after `**Status:**`, or "" when the ADR has no status line.
func status_of(source: String) -> String:
	for line: String in source.split("\n"):
		var found : RegExMatch = _status.search(line)
		if found != null:
			return found.get_string(1)
	return ""


## Every `quoted` path of the "In the code" section of [param source].
func code_paths(source: String) -> PackedStringArray:
	var out : PackedStringArray = []
	var inside : bool = false
	for line: String in source.split("\n"):
		if line.begins_with("## "):
			inside = line.strip_edges() == "## In the code"
		elif inside and line.strip_edges().begins_with("- "):
			for found: RegExMatch in _quoted.search_all(line.get_slice(":", 0) if ": " in line else line):
				out.append(found.get_string(1))
	return out


## A file or a folder; for a pattern (`native/*.cs`), the folder it is in.
func _exists(path: String) -> bool:
	if "*" in path:
		path = path.get_base_dir()
	return FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path.trim_suffix("/"))
