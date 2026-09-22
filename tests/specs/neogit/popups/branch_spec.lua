local eq = assert.are.same

local actions = require("neogit.popups.branch.actions")
local FuzzyFinderBuffer = require("neogit.buffers.fuzzy_finder")
local git = require("neogit.lib.git")

describe("branch popup suggestions", function()
  local original_fuzzy_new
  local original_current
  local original_list_branches
  local original_list_local_branches
  local original_list_remote_branches
  local original_list_tags
  local original_heads
  local captured

  local function popup(ref_name, commits)
    return {
      state = { env = { ref_name = ref_name, commits = commits } },
      get_arguments = function()
        return {}
      end,
    }
  end

  before_each(function()
    original_fuzzy_new = FuzzyFinderBuffer.new
    original_current = git.branch.current
    original_list_branches = git.refs.list_branches
    original_list_local_branches = git.refs.list_local_branches
    original_list_remote_branches = git.refs.list_remote_branches
    original_list_tags = git.refs.list_tags
    original_heads = git.refs.heads

    FuzzyFinderBuffer.new = function(options)
      captured = options
      return {
        open_async = function()
          return nil
        end,
      }
    end

    git.branch.current = function()
      return "main"
    end
    git.refs.list_branches = function()
      return { "main", "feature", "origin/topic" }
    end
    git.refs.list_local_branches = function()
      return { "main", "feature" }
    end
    git.refs.list_remote_branches = function()
      return { "origin/topic" }
    end
    git.refs.list_tags = function()
      return { "v1.0.0" }
    end
    git.refs.heads = function()
      return { "HEAD" }
    end
  end)

  after_each(function()
    FuzzyFinderBuffer.new = original_fuzzy_new
    git.branch.current = original_current
    git.refs.list_branches = original_list_branches
    git.refs.list_local_branches = original_list_local_branches
    git.refs.list_remote_branches = original_list_remote_branches
    git.refs.list_tags = original_list_tags
    git.refs.heads = original_heads
  end)

  it("puts the hovered ref first when checking out a branch or revision", function()
    actions.checkout_branch_revision(popup("feature", { "0123456" }))

    eq("feature", captured[1])
    eq("0123456", captured[2])
  end)

  it("puts an eligible hovered remote first in the local branch selector", function()
    actions.checkout_local_branch(popup("origin/topic"))

    eq({ "origin/topic", "main", "feature" }, captured)
  end)

  it("does not inject an ineligible ref into the local branch selector", function()
    actions.checkout_local_branch(popup("0123456"))

    eq({ "main", "feature", "origin/topic" }, captured)
  end)

  it("puts the hovered ref first in both new branch start-point selectors", function()
    for _, action in ipairs { actions.checkout_create_branch, actions.create_branch } do
      action(popup("origin/topic", { "0123456" }))
      eq("origin/topic", captured[1])
      eq("0123456", captured[2])
    end
  end)
end)
