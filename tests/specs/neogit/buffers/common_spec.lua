local eq = assert.are.same

local Common = require("neogit.buffers.common")
local Renderer = require("neogit.lib.ui.renderer")
local Ui = require("neogit.lib.ui")

local function commit(ref_name)
  return {
    oid = "0123456789abcdef",
    abbreviated_commit = "0123456",
    ref_name = ref_name,
    rel_date = "now",
    log_date = "now",
    graph = "",
    subject = "subject",
    body = "",
    author_name = "Author",
    author_email = "author@example.com",
    author_date = "now",
    committer_name = "Committer",
    committer_email = "committer@example.com",
    committer_date = "now",
  }
end

local function branch_components(ref_name, remotes)
  local layout = Ui.col {
    Common.CommitEntry(commit(ref_name), remotes or {}, {
      decorate = true,
      details = false,
      graph = false,
    }),
  }
  local renderer = Renderer:new(layout, {
    create_namespace = function()
      return 1
    end,
  }):render()

  local result = {}
  for _, component in ipairs(renderer:node_index():find_by_line(1)) do
    if component.options.branch_ref then
      table.insert(result, { component.value, component.options.branch_ref })
    end
  end

  return result
end

describe("CommitEntry branch decorations", function()
  it("annotates a local branch", function()
    eq({ { "feature", "feature" } }, branch_components("feature"))
  end)

  it("distinguishes a remote prefix from its local branch", function()
    eq({
      { "origin/", "origin/feature" },
      { "feature", "feature" },
    }, branch_components("feature, origin/feature", { "origin" }))
  end)

  it("annotates both parts of a remote-only branch", function()
    eq({
      { "origin/", "origin/feature" },
      { "feature", "origin/feature" },
    }, branch_components("origin/feature", { "origin" }))
  end)

  it("distinguishes remotes in a grouped decoration", function()
    eq({
      { "origin", "origin/feature" },
      { "fork", "fork/feature" },
    }, branch_components("origin/feature, fork/feature", { "origin", "fork" }))
  end)

  it("does not annotate tags as branches", function()
    eq({}, branch_components("tag: v1.0.0"))
  end)
end)
