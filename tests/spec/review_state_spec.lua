local state = require("codex_workbench.ui.review.state")

describe("review state", function()
  before_each(function()
    state.reset()
  end)

  it("tracks accepted hunks and builds partial badges", function()
    local file = {
      path = "src/a.lua",
      hunks = { {}, {}, {} },
    }

    state.accept_hunk("src/a.lua", 1)

    assert.is_true(state.is_accepted("src/a.lua", 1))
    assert.is_false(state.is_accepted("src/a.lua", 0))
    assert.equals("[1/3 ✓]", state.badge(file))
  end)

  it("uses ASCII symbols when requested", function()
    local file = {
      path = "src/a.lua",
      hunks = { {} },
    }

    state.reject_file("src/a.lua")

    assert.is_true(state.is_rejected("src/a.lua", 0))
    assert.equals("[1 hunk · [ng]]", state.badge(file, { ascii_only = true }))
  end)

  it("keeps file and hunk state mutually consistent", function()
    local file = {
      path = "src/a.lua",
      hunks = { {}, {} },
    }

    state.accept_file("src/a.lua")
    state.reject_hunk("src/a.lua", 1)

    assert.is_nil(state.is_accepted("src/a.lua", 0))
    assert.is_true(state.is_rejected("src/a.lua", 1))
    assert.equals("[1/2 ✗]", state.badge(file))

    state.accept_file("src/a.lua")
    assert.is_true(state.is_accepted("src/a.lua", 0))
    assert.is_nil(state.is_rejected("src/a.lua", 1))
    assert.equals("[2 hunks · ✓]", state.badge(file))
  end)

  it("ignores out-of-range hunk keys when rendering badges", function()
    local file = {
      path = "src/a.lua",
      hunks = { {} },
    }

    state.accept_hunk("src/a.lua", 0)
    state.accept_hunk("src/a.lua", 5)

    assert.equals("[1 hunk · ✓]", state.badge(file))
  end)
end)
