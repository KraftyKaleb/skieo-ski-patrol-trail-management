-- Remembers which runs the patrol closed, so a run it closed before you
-- quit is still reopened after you load the save again. Runs are keyed by
-- trail ID plus the start point (to the metre), because the game reuses the
-- IDs of deleted runs. One line per run: key, closed-at hour, reason IDs.
-- A `~weather` line keeps the new-snow model, so avalanche danger survives a
-- restart. It is only used when the loaded save's clock is within two days.
local Store = {}

function Store.weather_record(w)
    return {closed_at = w.hours, reasons = {string.format('%.3f', w.new_snow_cm), w.warm and 'warm' or 'dry',
        w.last_blizzard and string.format('%.4f', w.last_blizzard) or 'none'}}
end

function Store.restore_weather(record, w, now)
    if not record or not record.closed_at or math.abs(now - record.closed_at) > 48 then return false end
    w.new_snow_cm = tonumber(record.reasons[1]) or 0
    w.warm = record.reasons[2] == 'warm'
    w.last_blizzard = tonumber(record.reasons[3])
    w.hours = record.closed_at
    return true
end

function Store.key(trail)
    local p = trail.curves[1] and trail.curves[1][1] or {x = 0, y = 0}
    return string.format('%d@%d,%d', trail.id, math.floor(p.x / 100 + 0.5), math.floor(p.y / 100 + 0.5))
end

function Store.load(path)
    local records = {}
    local f = path and io.open(path, 'r')
    if not f then return records end
    for line in f:lines() do
        local key, closed_at, reasons = line:match('^([^\t]+)\t([^\t]*)\t([^\t]*)$')
        if key then
            local list = {}
            for id in reasons:gmatch('[^,]+') do list[#list + 1] = id end
            records[key] = {closed_at = tonumber(closed_at), reasons = list}
        end
    end
    f:close()
    return records
end

function Store.save(path, records)
    if not path then return false end
    local keys = {}
    for key in pairs(records) do keys[#keys + 1] = key end
    table.sort(keys)
    local lines = {}
    for _, key in ipairs(keys) do
        local r = records[key]
        lines[#lines + 1] = string.format('%s\t%s\t%s', key, r.closed_at and string.format('%.4f', r.closed_at) or '', table.concat(r.reasons or {}, ','))
    end
    local f = io.open(path, 'w')
    if not f then return false end
    f:write(table.concat(lines, '\n'), #lines > 0 and '\n' or '')
    f:close()
    return true
end

return Store
