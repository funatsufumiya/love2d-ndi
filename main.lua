local ndi = require("ndi")
local canvas

function love.load()
    love.window.setMode(640,480)
    canvas = love.graphics.newCanvas(640,480)
    local ok, err = ndi.init("love2d NDI Sender")
    if not ok then
        print("NDI init error:", err)
    else
        print("NDI initialized. Source:", ndi.getSourceName() or "(unknown)")
    end
end

local t = 0
local ok = nil
local err = nil
function love.update(dt)
    t = t + dt
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0.15,0.15,0.15,1)
    love.graphics.setColor(1,1,1,1)
    love.graphics.print(string.format("NDI test time: %.2f", t), 20,20)
    love.graphics.setColor(0.2,0.6,0.9,1)
    love.graphics.rectangle("fill", 100,100,200,150)
    love.graphics.setColor(1,1,1,1)
    love.graphics.circle("fill", 400 + math.sin(t*2)*50, 200, 40)
    love.graphics.setCanvas()

    ok, err = ndi.sendCanvas(canvas)
    -- if not ok then
    --     -- optional: print once
    --     -- love.graphics.print("NDI send error:", err)
    -- end
end

function love.draw()
    love.graphics.setColor(1,1,1)
    love.graphics.draw(canvas, 0, 0)

    if not ok then
        love.graphics.print("NDI send error:" .. err, 20, 200)
    end

    local fps = love.timer.getFPS()
    -- local fps = 1 / delta

    love.graphics.print(string.format("FPS: %.2f", fps), 20, 50)
end

function love.quit()
    ndi.shutdown()
end
