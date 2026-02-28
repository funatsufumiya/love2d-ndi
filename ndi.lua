local ffi = require("ffi")

local ndi = {}
local C = nil
local lib = nil

-- compute FourCC like NDI_LIB_FOURCC macro
local function fourcc(a,b,c,d)
    return string.byte(a) + string.byte(b)*256 + string.byte(c)*65536 + string.byte(d)*16777216
end
local FOURCC_BGRA = fourcc('B','G','R','A')
local FOURCC_RGBA = fourcc('R','G','B','A')

ffi.cdef[[
typedef void* NDIlib_send_instance_t;
typedef unsigned int uint32_t; typedef unsigned char uint8_t; typedef long long int64_t;
typedef struct { const char* p_ndi_name; const char* p_groups; int clock_video; int clock_audio; } NDIlib_send_create_t;
typedef struct {
    int xres; int yres; uint32_t FourCC; int frame_rate_N; int frame_rate_D; float picture_aspect_ratio; int frame_format_type; int64_t timecode; uint8_t* p_data; int line_stride_in_bytes; const char* p_metadata; int64_t timestamp;
} NDIlib_video_frame_v2_t;
typedef struct { const char* p_ndi_name; const char* p_url_address; } NDIlib_source_t;

int NDIlib_initialize(void);
void NDIlib_destroy(void);
NDIlib_send_instance_t NDIlib_send_create(const NDIlib_send_create_t* p_create_settings);
void NDIlib_send_destroy(NDIlib_send_instance_t p_instance);
void NDIlib_send_send_video_v2(NDIlib_send_instance_t p_instance, const NDIlib_video_frame_v2_t* p_video_data);
int NDIlib_send_get_no_connections(NDIlib_send_instance_t p_instance, uint32_t timeout_in_ms);
const NDIlib_source_t* NDIlib_send_get_source_name(NDIlib_send_instance_t p_instance);
]]

local function try_load_candidates()
    local candidates = {"Processing.NDI.Lib.x64.dll", "Processing.NDI.Lib.dll", "libndi.so", "libndi.dylib"}
    for _, name in ipairs(candidates) do
        local ok, l = pcall(ffi.load, name)
        if ok then return l end
    end
    for _, name in ipairs({"Processing.NDI.Lib", "ndi"}) do
        local ok, l = pcall(ffi.load, name)
        if ok then return l end
    end
    return nil
end

local function ensure_lib()
    if lib then return true end
    lib = try_load_candidates()
    if not lib then return false, "NDI native library not found (tried common names)" end
    C = lib
    return true
end

function ndi.init(name)
    local ok, err = ensure_lib()
    if not ok then return nil, err end
    if C.NDIlib_initialize() == 0 then return nil, "NDI initialize failed" end
    local create = ffi.new("NDIlib_send_create_t")
    create.p_ndi_name = name or "love2d NDI"
    create.p_groups = nil
    create.clock_video = 0
    create.clock_audio = 0
    local instance = C.NDIlib_send_create(create)
    if instance == nil then
        C.NDIlib_destroy()
        return nil, "NDI send_create failed"
    end
    ndi._instance = instance
    -- LÖVE ImageData is typically RGBA8 in memory; use RGBA FourCC by default.
    ndi._format = FOURCC_RGBA
    return true
end

-- Try to obtain raw pointer from ImageData for fast path. If unavailable,
-- fall back to per-pixel read (slow).
local function imageDataToRaw(imageData)
    local w = imageData:getWidth()
    local h = imageData:getHeight()
    -- Check pixel format first (if available) and warn/fallback if unsupported.
    local fmt = nil
    if type(imageData.getFormat) == "function" then
        fmt = imageData:getFormat()
        local allowed = { rgba8 = true, normal = true, srgba8 = true }
        if not allowed[fmt] then
            print("NDI warning: ImageData format '" .. tostring(fmt) .. "' not supported for fast pointer path; falling back to safe conversion")
            fmt = nil
        end
    else
        print("NDI warning: ImageData:getFormat() not available; falling back to safe conversion")
    end

    -- Fast path: only use getPointer when format is known and supported
    if fmt and type(imageData.getPointer) == "function" then
        local ok, p = pcall(function() return imageData:getPointer() end)
        if ok and p then
            -- Assume pointer points to contiguous RGBA8 bytes with stride w*4
            return p, w * h * 4, true, w * 4, w, h
        end
    end

    -- Fallback: build packed RGBA string (slow)
    local t = {}
    local insert = table.insert
    for y=0,h-1 do
        for x=0,w-1 do
            local r,g,b,a = imageData:getPixel(x,y)
            local R = math.floor(r * 255 + 0.5)
            local G = math.floor(g * 255 + 0.5)
            local B = math.floor(b * 255 + 0.5)
            local A = math.floor(a * 255 + 0.5)
            insert(t, string.char(R, G, B, A))
        end
    end
    local s = table.concat(t)
    return s, #s, false, w * 4, w, h
end

function ndi.sendImageData(imageData)
    if not ndi._instance then return nil, "NDI not initialized" end
    local w = imageData:getWidth()
    local h = imageData:getHeight()
    local raw, len, isptr, stride = imageDataToRaw(imageData)
    local buf
    local frame = ffi.new("NDIlib_video_frame_v2_t")
    frame.xres = w
    frame.yres = h
    frame.FourCC = ndi._format
    frame.frame_rate_N = 30
    frame.frame_rate_D = 1
    frame.picture_aspect_ratio = w / h
    frame.frame_format_type = 0
    frame.timecode = 0
    if isptr then
        -- raw is a pointer/lightuserdata; cast to uint8_t*
        frame.p_data = ffi.cast("uint8_t*", raw)
        frame.line_stride_in_bytes = stride
    else
        buf = ffi.new("uint8_t[?]", len)
        ffi.copy(buf, raw, len)
        frame.p_data = buf
        frame.line_stride_in_bytes = w * 4
    end
    frame.p_metadata = nil
    frame.timestamp = 0
    C.NDIlib_send_send_video_v2(ndi._instance, frame)
    return true
end

function ndi.sendCanvas(canvas)
    if type(canvas.newImageData) ~= "function" then
        return nil, "canvas:newImageData() not available on this object"
    end
    local img = canvas:newImageData()
    return ndi.sendImageData(img)
end

function ndi.getSourceName()
    if not ndi._instance then return nil end
    local s = C.NDIlib_send_get_source_name(ndi._instance)
    if s == nil then return nil end
    return ffi.string(s.p_ndi_name)
end

function ndi.shutdown()
    if ndi._instance and C then
        C.NDIlib_send_destroy(ndi._instance)
        ndi._instance = nil
    end
    if C then
        C.NDIlib_destroy()
        C = nil; lib = nil
    end
end

return ndi
