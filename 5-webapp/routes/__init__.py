"""
Flask blueprints - one module per action domain, mirroring actions/. A
route module only does HTTP glue (parsing the request body, mapping
ActionError -> a 400 JSON response, calling the matching actions/
function); it holds no logic of its own. See "Adding a new action" in
README.md.
"""
