-- yes/no confirmations on the norns screen (K3 yes / K2 no). they never
-- block the midimix: whatever asks waits for the answer through callbacks.
local Q = {queue = {}}

-- lines: 1-2 strings. leave_menu: the question came from the norns menu,
-- so drop back to the play screen where the dialog is drawn
function Q.ask(lines, on_yes, on_no, leave_menu)
  table.insert(Q.queue, {lines = lines, yes = on_yes, no = on_no})
  if leave_menu and _menu and _menu.mode then
    clock.run(function()
      clock.sleep(0.15)
      _menu.set_mode(false)
    end)
  end
end

function Q.active() return Q.queue[1] ~= nil end

-- returns true if the key press was used by a dialog
function Q.key(n)
  local c = Q.queue[1]
  if not c then return false end
  if n == 3 then
    table.remove(Q.queue, 1)
    if c.yes then c.yes() end
  elseif n == 2 then
    table.remove(Q.queue, 1)
    if c.no then c.no() end
  end
  return true
end

return Q
