local eq = assert.are.same

local Ui = require("neogit.lib.ui")

describe("Ui branch refs", function()
  local original_get_cursor
  local cursor

  before_each(function()
    original_get_cursor = vim.api.nvim_win_get_cursor
    cursor = { 3, 0 }
    vim.api.nvim_win_get_cursor = function()
      return cursor
    end
  end)

  after_each(function()
    vim.api.nvim_win_get_cursor = original_get_cursor
  end)

  it("returns the branch ref at the exact cursor column", function()
    local ui = Ui.new {}
    ui.node_index = {
      find_by_line = function(_, line)
        if line ~= 3 then
          return {}
        end

        return {
          {
            options = { branch_ref = "origin/feature" },
            position = { col_start = 8, col_end = 14 },
          },
          {
            options = { branch_ref = "feature" },
            position = { col_start = 15, col_end = 21 },
          },
        }
      end,
    }

    cursor[2] = 8
    eq("origin/feature", ui:get_branch_ref_under_cursor())

    cursor[2] = 14
    eq("origin/feature", ui:get_branch_ref_under_cursor())

    cursor[2] = 15
    eq("feature", ui:get_branch_ref_under_cursor())

    cursor[2] = 22
    assert.is_nil(ui:get_branch_ref_under_cursor())
  end)
end)
