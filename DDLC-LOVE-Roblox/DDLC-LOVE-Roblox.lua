--[[
================================================================================
 DDLC-LOVE for Roblox  —  single-file loadstring port
--------------------------------------------------------------------------------
 An unofficial Roblox (executor) port of DDLC-LOVE (LukeZGD), which is an
 unofficial port of Doki Doki Literature Club (Team Salvato).
 Support the official game: https://ddlc.moe  /  https://ddlc.plus

 HOW TO RUN (in an executor):
     loadstring(game:HttpGet("https://YOUR-HOST/DDLC-LOVE-Roblox.lua"))()
 or simply paste this whole file into the executor and run it.

 WHAT IT DOES:
   * Implements a Love2D (LÖVE 0.10) compatibility layer on top of Roblox
     (ScreenGui renderer with getcustomasset, or Drawing API fallback).
   * Fetches the original game code (unmodified, from the official
     LukeZGD/DDLC-LOVE 'ddlclove' branch) and the game assets
     (LukeZGD/DDLC-LOVE-Assets) at runtime and caches them on disk.
   * Saves/settings are stored in the executor workspace folder:
         workspace/DDLC-LOVE/
 CONTROLS (keyboard):
     Space / Enter ......... advance text, confirm
     Esc / Backspace ....... cancel, hide text window
     1 or Shift ............ pause menu
     2 ..................... skip toggle
     3 ..................... auto-forward toggle
     Arrows ................ menu navigation / poem scroll
 Touch devices get an on-screen pad automatically.
================================================================================
]]

--==============================================================================
-- CONFIG (edit if you want to self-host the files)
--==============================================================================
local CODE_BASES = {
        "https://raw.githubusercontent.com/LukeZGD/DDLC-LOVE/ddlclove/game",
        "https://cdn.jsdelivr.net/gh/LukeZGD/DDLC-LOVE@ddlclove/game",
}
local ASSET_BASES = {
        "https://raw.githubusercontent.com/LukeZGD/DDLC-LOVE-Assets/master/ddlclove",
        "https://cdn.jsdelivr.net/gh/LukeZGD/DDLC-LOVE-Assets@master/ddlclove",
}
local SAVE_DIR = "DDLC-LOVE/"          -- inside the executor workspace folder
local GAME_W, GAME_H = 1280, 720       -- logical resolution of the game

--==============================================================================
-- SESSION CLEANUP (safe re-running of the script)
--==============================================================================
local genv = (type(getgenv) == "function" and getgenv()) or _G
if genv.__DDLC_LOVE_ROBLOX_SESSION then
        local s = genv.__DDLC_LOVE_ROBLOX_SESSION
        genv.__DDLC_LOVE_ROBLOX_SESSION = nil
        if type(s.destroy) == "function" then pcall(s.destroy) end
end
local session = {}
genv.__DDLC_LOVE_ROBLOX_SESSION = session

--==============================================================================
-- ENVIRONMENT / CAPABILITIES
--==============================================================================
local fmt = string.format
local function ttype(v) return type(v) end
local hasDrawing = (type(Drawing) == "table" or type(Drawing) == "userdata")
        and type(Drawing.new) == "function"
local hasCustomAsset = type(getcustomasset) == "function"
local hasWrite = type(writefile) == "function" and type(readfile) == "function"
        and type(isfile) == "function"
local hasAppend = type(appendfile) == "function"
local hasMakeFolder = type(makefolder) == "function"
local hasInstance = type(Instance) == "function"
local hasHttpGet = (type(game) == "table" or type(game) == "userdata")
        and type(game.HttpGet) == "function"

local requestImpl
do
        local cands = {syn and syn.request, request, http and http.request, http_request}
        for _, f in ipairs(cands) do
                if type(f) == "function" then requestImpl = f break end
        end
end
local hasNetwork = hasHttpGet or requestImpl ~= nil

local function mkstatus(msg) session.lastStatus = msg end
local print_ = print
local warn_ = type(warn) == "function" and warn or print
local warned = {}
local function warnOnce(msg)
        if warned[msg] then return end
        warned[msg] = true
        warn_("[DDLC-LOVE] " .. msg)
end

if not hasNetwork then
        error("[DDLC-LOVE] This environment has no HTTP access (need game:HttpGet or request). "
                .. "Run the script inside a Roblox executor.", 0)
end
if not unpack then unpack = table.unpack end

--==============================================================================
-- UTILITIES
--==============================================================================
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

local function ensureDir(path)
        if not hasMakeFolder then return end
        local dir = path:match("^(.*)/[^/]+$")
        if dir and dir ~= "" then pcall(makefolder, dir) end
end

-- all paths here are relative to the executor workspace root
local function isFileRaw(path)
        local ok, res = pcall(isfile, path)
        return ok and res == true
end

-- write to path; if the executor cannot create subfolders, fall back to a
-- flat file name ("a/b/c" -> "a__b__c")
local function writeFile(path, data)
        if not hasWrite then return false, nil end
        ensureDir(path)
        if pcall(writefile, path, data) then return true, path end
        if path:find("/") then
                local flat = path:gsub("/", "__")
                if pcall(writefile, flat, data) then return true, flat end
        end
        return false, nil
end

local function readFile(path)
        if not hasWrite then return nil end
        local ok, data = pcall(readfile, path)
        if ok and type(data) == "string" then return data end
        if path:find("/") then
                ok, data = pcall(readfile, path:gsub("/", "__"))
                if ok and type(data) == "string" then return data end
        end
        return nil
end

local function isFile(path)
        if not hasWrite then return false end
        if isFileRaw(path) then return true end
        if path:find("/") and isFileRaw(path:gsub("/", "__")) then return true end
        return false
end

local function resolveFilePath(path)
        if isFileRaw(path) then return path end
        if path:find("/") then
                local flat = path:gsub("/", "__")
                if isFileRaw(flat) then return flat end
        end
        return nil
end

local function appendFileData(path, data)
        if hasAppend then
                local real = resolveFilePath(path) or path
                ensureDir(real)
                if pcall(appendfile, real, data) then return true end
        end
        local old = readFile(path)
        return (writeFile(path, (old or "") .. data))
end

-- djb2 hash for cache file names
local function urlHash(s)
        local h = 5381
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
        return fmt("%08x", h)
end

-- HTTP -----------------------------------------------------------------------
local function httpGetBody(url)
        -- prefer a real request implementation (guaranteed binary-safe)
        if requestImpl then
                local ok, res = pcall(requestImpl, { Url = url, Method = "GET" })
                if ok and type(res) == "table" and res.Success and type(res.Body) == "string" and #res.Body > 0 then
                        return res.Body
                end
        end
        if hasHttpGet then
                local ok, body = pcall(game.HttpGet, game, url)
                if ok and type(body) == "string" and #body > 0 then
                        return body
                end
        end
        return nil
end

local function fetchFromBases(bases, path)
        for i = 1, #bases do
                local body = httpGetBody(bases[i] .. "/" .. path)
                if body then return body end
        end
        return nil
end

-- image dimension parsing (PNG / JPEG headers) --------------------------------
local function imageDims(data)
        if #data < 24 then return nil end
        local function b(i) return data:byte(i) end
        if b(1) == 0x89 and data:sub(2, 4) == "PNG" then
                local w = b(17) * 16777216 + b(18) * 65536 + b(19) * 256 + b(20)
                local h = b(21) * 16777216 + b(22) * 65536 + b(23) * 256 + b(24)
                if w > 0 and h > 0 then return w, h end
                return nil
        end
        if b(1) == 0xFF and b(2) == 0xD8 then
                local i = 3
                while i < #data - 9 do
                        if b(i) ~= 0xFF then
                                i = i + 1
                        else
                                local m = b(i + 1)
                                if m == 0xD8 or (m >= 0xD0 and m <= 0xD9) or m == 0x01 or m == 0xFF then
                                        i = i + 2
                                elseif m == 0xC0 or m == 0xC1 or m == 0xC2 or m == 0xC3 or m == 0xC5
                                        or m == 0xC6 or m == 0xC7 or m == 0xC9 or m == 0xCA or m == 0xCB
                                        or m == 0xCD or m == 0xCE or m == 0xCF then
                                        local h = b(i + 6) * 256 + b(i + 7)
                                        local w = b(i + 8) * 256 + b(i + 9)
                                        if w > 0 and h > 0 then return w, h end
                                        return nil
                                else
                                        local len = b(i + 2) * 256 + b(i + 3)
                                        if len < 2 then return nil end
                                        i = i + 2 + len
                                end
                        end
                end
        end
        return nil
end

-- binary-safe base64 decode (for embedded assets, if ever needed) ------------
-- (reserved for future use)

--==============================================================================
-- ASSET MANIFEST (every asset shipped with the official DDLC-LOVE release;
-- used so love.filesystem.getInfo() can answer instantly for asset paths)
--==============================================================================
local ASSET_MANIFEST_RAW = [[
assets/audio/bgm/1-loop.ogg
assets/audio/bgm/1.ogg
assets/audio/bgm/10-loop.ogg
assets/audio/bgm/10-yuri.ogg
assets/audio/bgm/10.ogg
assets/audio/bgm/2-loop.ogg
assets/audio/bgm/2.ogg
assets/audio/bgm/2g.ogg
assets/audio/bgm/2g2.ogg
assets/audio/bgm/2gs.ogg
assets/audio/bgm/2gs2.ogg
assets/audio/bgm/2gs3.ogg
assets/audio/bgm/3-loop.ogg
assets/audio/bgm/3.ogg
assets/audio/bgm/3g.ogg
assets/audio/bgm/3g2.ogg
assets/audio/bgm/3g3.ogg
assets/audio/bgm/4-loop.ogg
assets/audio/bgm/4.ogg
assets/audio/bgm/4g-loop.ogg
assets/audio/bgm/4g.ogg
assets/audio/bgm/5-loop.ogg
assets/audio/bgm/5.ogg
assets/audio/bgm/5_ghost.ogg
assets/audio/bgm/5_monika-loop.ogg
assets/audio/bgm/5_monika.ogg
assets/audio/bgm/5_natsuki-loop.ogg
assets/audio/bgm/5_natsuki.ogg
assets/audio/bgm/5_sayori-loop.ogg
assets/audio/bgm/5_sayori.ogg
assets/audio/bgm/5_yuri-loop.ogg
assets/audio/bgm/5_yuri.ogg
assets/audio/bgm/5_yuri2.ogg
assets/audio/bgm/6-loop.ogg
assets/audio/bgm/6.ogg
assets/audio/bgm/6g-.ogg
assets/audio/bgm/6g.ogg
assets/audio/bgm/6o.ogg
assets/audio/bgm/6r.ogg
assets/audio/bgm/6s.ogg
assets/audio/bgm/7-loop.ogg
assets/audio/bgm/7.ogg
assets/audio/bgm/7a.ogg
assets/audio/bgm/7g-loop.ogg
assets/audio/bgm/7g.ogg
assets/audio/bgm/8-loop.ogg
assets/audio/bgm/8.ogg
assets/audio/bgm/9.ogg
assets/audio/bgm/9g.ogg
assets/audio/bgm/d-loop.ogg
assets/audio/bgm/d.ogg
assets/audio/bgm/eng/credits.ogg
assets/audio/bgm/eng/end-voice.ogg
assets/audio/bgm/g1.ogg
assets/audio/bgm/g2.ogg
assets/audio/bgm/ghostmenu.ogg
assets/audio/bgm/heartbeat.ogg
assets/audio/bgm/m1.ogg
assets/audio/bgm/monika-end-loop.ogg
assets/audio/bgm/monika-end.ogg
assets/audio/bgm/monika-start.ogg
assets/audio/bgm/s_kill_early.ogg
assets/audio/bgm/spa/credits.ogg
assets/audio/bgm/spa/end-voice.ogg
assets/audio/bgm/yuri-kill.ogg
assets/audio/sfx/baa.ogg
assets/audio/sfx/closet-close.ogg
assets/audio/sfx/closet-open.ogg
assets/audio/sfx/crack.ogg
assets/audio/sfx/error.ogg
assets/audio/sfx/eyes.ogg
assets/audio/sfx/fall.ogg
assets/audio/sfx/fall2.ogg
assets/audio/sfx/giggle.ogg
assets/audio/sfx/glitch1.ogg
assets/audio/sfx/glitch1s.ogg
assets/audio/sfx/glitch2.ogg
assets/audio/sfx/glitch3.ogg
assets/audio/sfx/gnid.ogg
assets/audio/sfx/hover.ogg
assets/audio/sfx/interference.ogg
assets/audio/sfx/monikapound.ogg
assets/audio/sfx/monikapound2.ogg
assets/audio/sfx/pageflip.ogg
assets/audio/sfx/run.ogg
assets/audio/sfx/s_kill_glitch1.ogg
assets/audio/sfx/s_kill_glitch1s.ogg
assets/audio/sfx/select.ogg
assets/audio/sfx/select_glitch.ogg
assets/audio/sfx/slap.ogg
assets/audio/sfx/smack.ogg
assets/audio/sfx/stab.ogg
assets/fonts/Aller_Rg.ttf
assets/fonts/F25_Bank_Printer.ttf
assets/fonts/Halogen.ttf
assets/fonts/RifficFree-Bold.ttf
assets/fonts/VerilySerifMono.ttf
assets/fonts/m1.ttf
assets/fonts/n1.ttf
assets/fonts/s1.ttf
assets/fonts/y1.ttf
assets/images/bg/GlitchSayoriScreen1.jpg
assets/images/bg/GlitchSayoriScreen2.jpg
assets/images/bg/Menu_bg_m.jpg
assets/images/bg/bedroom.jpg
assets/images/bg/black.jpg
assets/images/bg/cg/monika_bg.jpg
assets/images/bg/cg/monika_bg2.jpg
assets/images/bg/cg/monika_bg_glitch.jpg
assets/images/bg/cg/monika_rh.jpg
assets/images/bg/cg/n_cg1_base.jpg
assets/images/bg/cg/n_cg1b.jpg
assets/images/bg/cg/n_cg2_base.jpg
assets/images/bg/cg/n_cg3_base.jpg
assets/images/bg/cg/n_cg3_cake.jpg
assets/images/bg/cg/s_cg1.jpg
assets/images/bg/cg/s_cg2_base1.jpg
assets/images/bg/cg/s_cg2_base2.jpg
assets/images/bg/cg/s_cg3.jpg
assets/images/bg/cg/y_cg1_base.jpg
assets/images/bg/cg/y_cg2.jpg
assets/images/bg/cg/y_cg2_nochoc.jpg
assets/images/bg/cg/y_cg3_base.jpg
assets/images/bg/class.jpg
assets/images/bg/closet.jpg
assets/images/bg/club-skill.jpg
assets/images/bg/club.jpg
assets/images/bg/corridor.jpg
assets/images/bg/end-glitch1.jpg
assets/images/bg/end-glitch2.jpg
assets/images/bg/end-glitch3.jpg
assets/images/bg/ex3top.jpg
assets/images/bg/eyes.jpg
assets/images/bg/glitch.jpg
assets/images/bg/house.jpg
assets/images/bg/kitchen.jpg
assets/images/bg/noise1.jpg
assets/images/bg/noise2.jpg
assets/images/bg/noise3.jpg
assets/images/bg/noise4.jpg
assets/images/bg/notebook-glitch.jpg
assets/images/bg/notebook.jpg
assets/images/bg/poem.jpg
assets/images/bg/poem1.jpg
assets/images/bg/poem2.jpg
assets/images/bg/poem3.jpg
assets/images/bg/poem_y1.jpg
assets/images/bg/residential.jpg
assets/images/bg/s_kill/ex2.jpg
assets/images/bg/s_kill/s_kill_bg.jpg
assets/images/bg/s_kill/s_kill_bg2.jpg
assets/images/bg/s_kill/s_kill_bgzoom.jpg
assets/images/bg/save/bedroom.jpg
assets/images/bg/save/black.jpg
assets/images/bg/save/cg/n_cg1_base.jpg
assets/images/bg/save/cg/n_cg2_base.jpg
assets/images/bg/save/cg/n_cg3_base.jpg
assets/images/bg/save/cg/n_cg3_cake.jpg
assets/images/bg/save/cg/s_cg1.jpg
assets/images/bg/save/cg/s_cg2_base1.jpg
assets/images/bg/save/cg/s_cg2_base2.jpg
assets/images/bg/save/cg/s_cg3.jpg
assets/images/bg/save/cg/y_cg1_base.jpg
assets/images/bg/save/cg/y_cg2.jpg
assets/images/bg/save/cg/y_cg2_nochoc.jpg
assets/images/bg/save/cg/y_cg3_base.jpg
assets/images/bg/save/class.jpg
assets/images/bg/save/closet.jpg
assets/images/bg/save/club-skill.jpg
assets/images/bg/save/club.jpg
assets/images/bg/save/corridor.jpg
assets/images/bg/save/house.jpg
assets/images/bg/save/kitchen.jpg
assets/images/bg/save/notebook.jpg
assets/images/bg/save/residential.jpg
assets/images/bg/save/sayori_bedroom.jpg
assets/images/bg/sayori_bedroom.jpg
assets/images/bg/splash-glitch.jpg
assets/images/bg/splash-glitch2.jpg
assets/images/bg/splash.jpg
assets/images/bg/warning.jpg
assets/images/bg/warning2.jpg
assets/images/bg/y_kill/1a.jpg
assets/images/bg/y_kill/1b.jpg
assets/images/bg/y_kill/1c.jpg
assets/images/bg/y_kill/2a.jpg
assets/images/bg/y_kill/2b.jpg
assets/images/bg/y_kill/2c.jpg
assets/images/bg/y_kill/3a.jpg
assets/images/bg/y_kill/3b.jpg
assets/images/bg/y_kill/3c.jpg
assets/images/cg/blank.png
assets/images/cg/credits/1.jpg
assets/images/cg/credits/10.jpg
assets/images/cg/credits/1b.jpg
assets/images/cg/credits/2.jpg
assets/images/cg/credits/2b.jpg
assets/images/cg/credits/3.jpg
assets/images/cg/credits/4.jpg
assets/images/cg/credits/5.jpg
assets/images/cg/credits/5b.jpg
assets/images/cg/credits/6.jpg
assets/images/cg/credits/6b.jpg
assets/images/cg/credits/7.jpg
assets/images/cg/credits/7b.jpg
assets/images/cg/credits/8.jpg
assets/images/cg/credits/8b.jpg
assets/images/cg/credits/9.jpg
assets/images/cg/credits/9b.jpg
assets/images/cg/credits/ddlc.jpg
assets/images/cg/credits/splashw.jpg
assets/images/cg/monika_glitch1.png
assets/images/cg/monika_glitch2.png
assets/images/cg/monika_glitch3.png
assets/images/cg/monika_glitch4.png
assets/images/cg/n_cg1_exp1.png
assets/images/cg/n_cg1_exp2.png
assets/images/cg/n_cg1_exp3.png
assets/images/cg/n_cg1_exp4.png
assets/images/cg/n_cg1_exp5.png
assets/images/cg/n_cg2_exp1.png
assets/images/cg/n_cg2_exp2.png
assets/images/cg/n_cg3_exp1.png
assets/images/cg/n_cg3_exp2.png
assets/images/cg/s_cg2_exp1.png
assets/images/cg/s_cg2_exp2.png
assets/images/cg/s_cg2_exp3.png
assets/images/cg/s_kill/s_kill.png
assets/images/cg/s_kill/s_kill2.png
assets/images/cg/s_kill/s_kill_early.png
assets/images/cg/s_kill/s_killzoom.png
assets/images/cg/vignette.png
assets/images/cg/y_cg1_exp1.png
assets/images/cg/y_cg1_exp2.png
assets/images/cg/y_cg1_exp3.png
assets/images/cg/y_cg2_exp2.png
assets/images/cg/y_cg2_exp3.png
assets/images/cg/y_cg3_exp1.png
assets/images/gui/blood_drop.png
assets/images/gui/button/box.png
assets/images/gui/button/check_selected_foreground.png
assets/images/gui/button/choice_hover_background.png
assets/images/gui/button/choice_idle_background.png
assets/images/gui/button/slot_hover_background.png
assets/images/gui/button/slot_idle_background.png
assets/images/gui/ctc.png
assets/images/gui/eng/end.png
assets/images/gui/eng/endflipped.png
assets/images/gui/eng/gamebuttons.png
assets/images/gui/eng/gamemenu.png
assets/images/gui/eng/history.png
assets/images/gui/eng/load.png
assets/images/gui/eng/mainbuttons.png
assets/images/gui/eng/newgame.png
assets/images/gui/eng/newgame1.png
assets/images/gui/eng/save.png
assets/images/gui/eng/setbuttons.png
assets/images/gui/eng/settings.png
assets/images/gui/icon.png
assets/images/gui/logo.png
assets/images/gui/menu_art_m.png
assets/images/gui/menu_art_m_ghost.png
assets/images/gui/menu_art_n.png
assets/images/gui/menu_art_n_ghost.png
assets/images/gui/menu_art_s.png
assets/images/gui/menu_art_s_break.png
assets/images/gui/menu_art_s_ghost.png
assets/images/gui/menu_art_y.png
assets/images/gui/menu_art_y_ghost.png
assets/images/gui/menu_bg.jpg
assets/images/gui/menu_bg_m.jpg
assets/images/gui/menu_particle.png
assets/images/gui/namebox.png
assets/images/gui/overlay/confirm.png
assets/images/gui/overlay/game_menu.png
assets/images/gui/overlay/main_menu.png
assets/images/gui/overlay/sidebar.png
assets/images/gui/poemgame/m_sticker_1.png
assets/images/gui/poemgame/m_sticker_2.png
assets/images/gui/poemgame/n_sticker_1.png
assets/images/gui/poemgame/n_sticker_2.png
assets/images/gui/poemgame/poemtime.png
assets/images/gui/poemgame/poemtime2.png
assets/images/gui/poemgame/s_sticker_1.png
assets/images/gui/poemgame/s_sticker_2.png
assets/images/gui/poemgame/y_sticker_1.png
assets/images/gui/poemgame/y_sticker_1_broken.png
assets/images/gui/poemgame/y_sticker_2.png
assets/images/gui/poemgame/y_sticker_2g.png
assets/images/gui/poemgame/y_sticker_cut_1.png
assets/images/gui/poemgame/y_sticker_cut_2.png
assets/images/gui/scrollbar/horizontal_poem_bar.png
assets/images/gui/scrollbar/horizontal_poem_thumb.png
assets/images/gui/scrollbar/vertical_poem_bar.png
assets/images/gui/scrollbar/vertical_poem_thumb.png
assets/images/gui/skip.png
assets/images/gui/slider/horizontal_hover_thumb.png
assets/images/gui/spa/end.png
assets/images/gui/spa/endflipped.png
assets/images/gui/spa/gamebuttons.png
assets/images/gui/spa/gamemenu.png
assets/images/gui/spa/history.png
assets/images/gui/spa/load.png
assets/images/gui/spa/mainbuttons.png
assets/images/gui/spa/newgame.png
assets/images/gui/spa/newgame1.png
assets/images/gui/spa/save.png
assets/images/gui/spa/setbuttons.png
assets/images/gui/spa/settings.png
assets/images/gui/textbox.png
assets/images/gui/textbox_monika.png
assets/images/monika/1l.png
assets/images/monika/1lwho.png
assets/images/monika/1r.png
assets/images/monika/2l.png
assets/images/monika/2r.png
assets/images/monika/3a.png
assets/images/monika/3b.png
assets/images/monika/a.png
assets/images/monika/ac.png
assets/images/monika/b.png
assets/images/monika/c.png
assets/images/monika/d.png
assets/images/monika/e.png
assets/images/monika/f.png
assets/images/monika/g.png
assets/images/monika/g1.png
assets/images/monika/g2.png
assets/images/monika/g3.png
assets/images/monika/g4.png
assets/images/monika/h.png
assets/images/monika/i.png
assets/images/monika/j.png
assets/images/monika/k.png
assets/images/monika/l.png
assets/images/monika/m.png
assets/images/monika/n.png
assets/images/monika/o.png
assets/images/monika/p.png
assets/images/monika/q.png
assets/images/monika/r.png
assets/images/natsuki/1bl.png
assets/images/natsuki/1br.png
assets/images/natsuki/1l.png
assets/images/natsuki/1r.png
assets/images/natsuki/1t.png
assets/images/natsuki/2a.png
assets/images/natsuki/2b.png
assets/images/natsuki/2bl.png
assets/images/natsuki/2br.png
assets/images/natsuki/2c.png
assets/images/natsuki/2d.png
assets/images/natsuki/2e.png
assets/images/natsuki/2f.png
assets/images/natsuki/2g.png
assets/images/natsuki/2h.png
assets/images/natsuki/2i.png
assets/images/natsuki/2l.png
assets/images/natsuki/2r.png
assets/images/natsuki/2t.png
assets/images/natsuki/3.png
assets/images/natsuki/3b.png
assets/images/natsuki/a.png
assets/images/natsuki/b.png
assets/images/natsuki/blackeyes.png
assets/images/natsuki/c.png
assets/images/natsuki/d.png
assets/images/natsuki/e.png
assets/images/natsuki/eye.png
assets/images/natsuki/f.png
assets/images/natsuki/f_1.png
assets/images/natsuki/f_1b.png
assets/images/natsuki/f_h.png
assets/images/natsuki/f_i.png
assets/images/natsuki/f_o.png
assets/images/natsuki/f_v.png
assets/images/natsuki/g.png
assets/images/natsuki/ghost1.png
assets/images/natsuki/ghost2.png
assets/images/natsuki/ghost3-1.png
assets/images/natsuki/ghost3-2.png
assets/images/natsuki/ghost3-3.png
assets/images/natsuki/ghost3.png
assets/images/natsuki/ghost_blood.png
assets/images/natsuki/glitch1.png
assets/images/natsuki/h.png
assets/images/natsuki/i.png
assets/images/natsuki/j.png
assets/images/natsuki/k.png
assets/images/natsuki/l.png
assets/images/natsuki/m.png
assets/images/natsuki/n.png
assets/images/natsuki/o.png
assets/images/natsuki/p.png
assets/images/natsuki/q.png
assets/images/natsuki/r.png
assets/images/natsuki/s.png
assets/images/natsuki/scream.png
assets/images/natsuki/t.png
assets/images/natsuki/u.png
assets/images/natsuki/v.png
assets/images/natsuki/vomit.png
assets/images/natsuki/w.png
assets/images/natsuki/x.png
assets/images/natsuki/y.png
assets/images/natsuki/z.png
assets/images/poem_special/eng/poem_end.jpg
assets/images/poem_special/eng/poem_end_clearall.jpg
assets/images/poem_special/eng/poem_special1.jpg
assets/images/poem_special/eng/poem_special10.jpg
assets/images/poem_special/eng/poem_special11.jpg
assets/images/poem_special/eng/poem_special2.jpg
assets/images/poem_special/eng/poem_special3.jpg
assets/images/poem_special/eng/poem_special4.jpg
assets/images/poem_special/eng/poem_special5a.jpg
assets/images/poem_special/eng/poem_special5b.jpg
assets/images/poem_special/eng/poem_special6.jpg
assets/images/poem_special/eng/poem_special8.jpg
assets/images/poem_special/eng/poem_special9.jpg
assets/images/poem_special/poem_special7a.png
assets/images/poem_special/poem_special7b.png
assets/images/poem_special/spa/poem_end.jpg
assets/images/poem_special/spa/poem_end_clearall.jpg
assets/images/poem_special/spa/poem_special1.jpg
assets/images/poem_special/spa/poem_special10.jpg
assets/images/poem_special/spa/poem_special11.jpg
assets/images/poem_special/spa/poem_special2.jpg
assets/images/poem_special/spa/poem_special3.jpg
assets/images/poem_special/spa/poem_special4.jpg
assets/images/poem_special/spa/poem_special5a.jpg
assets/images/poem_special/spa/poem_special5b.jpg
assets/images/poem_special/spa/poem_special6.jpg
assets/images/poem_special/spa/poem_special8.jpg
assets/images/poem_special/spa/poem_special9.jpg
assets/images/sayori/1bl.png
assets/images/sayori/1br.png
assets/images/sayori/1l.png
assets/images/sayori/1r.png
assets/images/sayori/2bl.png
assets/images/sayori/2br.png
assets/images/sayori/2l.png
assets/images/sayori/2r.png
assets/images/sayori/3a.png
assets/images/sayori/3b.png
assets/images/sayori/3c.png
assets/images/sayori/3d.png
assets/images/sayori/a.png
assets/images/sayori/b.png
assets/images/sayori/c.png
assets/images/sayori/d.png
assets/images/sayori/e.png
assets/images/sayori/end-glitch1.png
assets/images/sayori/end-glitch2.png
assets/images/sayori/f.png
assets/images/sayori/f_1a.png
assets/images/sayori/f_1b.png
assets/images/sayori/g.png
assets/images/sayori/glitch1.png
assets/images/sayori/glitch2.png
assets/images/sayori/h.png
assets/images/sayori/i.png
assets/images/sayori/j.png
assets/images/sayori/k.png
assets/images/sayori/l.png
assets/images/sayori/m.png
assets/images/sayori/n.png
assets/images/sayori/o.png
assets/images/sayori/p.png
assets/images/sayori/q.png
assets/images/sayori/r.png
assets/images/sayori/s.png
assets/images/sayori/t.png
assets/images/sayori/u.png
assets/images/sayori/v.png
assets/images/sayori/w.png
assets/images/sayori/x.png
assets/images/sayori/y.png
assets/images/yuri/0a.png
assets/images/yuri/0b.png
assets/images/yuri/1bl.png
assets/images/yuri/1br.png
assets/images/yuri/1l.png
assets/images/yuri/1r.png
assets/images/yuri/2bl.png
assets/images/yuri/2br.png
assets/images/yuri/2l.png
assets/images/yuri/2r.png
assets/images/yuri/3.png
assets/images/yuri/3b.png
assets/images/yuri/a.png
assets/images/yuri/a2.png
assets/images/yuri/b.png
assets/images/yuri/b2.png
assets/images/yuri/c.png
assets/images/yuri/c2.png
assets/images/yuri/cuts.png
assets/images/yuri/d.png
assets/images/yuri/d2.png
assets/images/yuri/dragon1.png
assets/images/yuri/dragon2.png
assets/images/yuri/e.png
assets/images/yuri/e2.png
assets/images/yuri/eyes1.png
assets/images/yuri/eyes2.png
assets/images/yuri/eyesfull.png
assets/images/yuri/f.png
assets/images/yuri/f_2bs.png
assets/images/yuri/g.png
assets/images/yuri/glitch1.png
assets/images/yuri/glitch2.png
assets/images/yuri/glitch3.png
assets/images/yuri/glitch4.png
assets/images/yuri/glitch5.png
assets/images/yuri/h.png
assets/images/yuri/hisui.png
assets/images/yuri/i.png
assets/images/yuri/j.png
assets/images/yuri/k.png
assets/images/yuri/l.png
assets/images/yuri/m.png
assets/images/yuri/n.png
assets/images/yuri/o.png
assets/images/yuri/oneeye.png
assets/images/yuri/oneeye2.png
assets/images/yuri/p.png
assets/images/yuri/q.png
assets/images/yuri/r.png
assets/images/yuri/s.png
assets/images/yuri/stab/1.png
assets/images/yuri/stab/2.png
assets/images/yuri/stab/3.png
assets/images/yuri/stab/4.png
assets/images/yuri/stab/5.png
assets/images/yuri/stab/6-full.png
assets/images/yuri/stab/6.png
assets/images/yuri/t.png
assets/images/yuri/u.png
assets/images/yuri/v.png
assets/images/yuri/w.png
assets/images/yuri/y1.png
assets/images/yuri/y2.png
assets/images/yuri/y3.png
assets/images/yuri/y4.png
assets/images/yuri/y5.png
assets/images/yuri/y6.png
assets/images/yuri/y7.png
assets/images/yuri/za.png
assets/images/yuri/zb.png
assets/images/yuri/zc.png
assets/images/yuri/zd.png
]]

local manifest = {}
do
        local list = ASSET_MANIFEST_RAW
        for entry in list:gmatch("[^\n]+") do
                entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
                if entry ~= "" then manifest[entry] = true end
        end
end

--==============================================================================
-- ASSET PATH -> URL MAPPING
--==============================================================================
-- The archived LukeZGD/DDLC-LOVE-Assets repo stores assets under:
--   images -> ddlclove/switch/images/**       (.jpg converted to .png)
--   fonts  -> ddlclove/common/fonts/**
--   audio  -> ddlclove/common/audio/**        (.ogg converted to .mp3,
--                                              bgm X-loop.ogg stored as Xre.mp3)
-- plus a few renamed/special-cased files.
local function mapAssetURL(path)
        if path:sub(1, 14) == "assets/images/" then
                local sub = path:sub(15)
                sub = sub:gsub("^bg/s_kill/", "cg/s_kill/")
                sub = sub:gsub("^bg/y_kill/", "cg/y_kill/")
                if sub == "bg/ex3top.jpg" then sub = "gui/ex3top.png" end
                if sub == "cg/vignette.png" then sub = "bg/vignette.png" end
                sub = sub:gsub("%.jpg$", ".png")
                return "switch/images/" .. sub, ".png"
        elseif path:sub(1, 13) == "assets/audio/" then
                local sub = path:sub(14)
                sub = sub:gsub("%.ogg$", ".mp3")
                sub = sub:gsub("%-loop%.mp3$", "re.mp3")
                return "common/audio/" .. sub, ".mp3"
        elseif path:sub(1, 13) == "assets/fonts/" then
                return "common/fonts/" .. path:sub(14), ".ttf"
        end
        return nil, nil
end

-- language GUI images that are not in the public assets repo -> drawn natively
local PSEUDO = {}
for _, lang in ipairs({ "eng", "spa" }) do
        for _, n in ipairs({ "gamebuttons", "gamemenu", "history", "load", "mainbuttons",
                "newgame", "newgame1", "save", "setbuttons", "settings" }) do
                PSEUDO["assets/images/gui/" .. lang .. "/" .. n .. ".png"] = { lang = lang, name = n }
        end
end

-- binary asset cache ----------------------------------------------------------
local uriCache = {}   -- cachePath -> rbxasset uri (getcustomasset)
local function getAssetURI(url)
        local ext = url:match("%.(%w+)$") or "bin"
        local cachePath = SAVE_DIR .. "cache/" .. urlHash(url) .. "." .. ext
        if uriCache[cachePath] then return uriCache[cachePath] end
        local realPath = resolveFilePath(cachePath)
        local data = realPath and readFile(realPath) or nil
        if not data then
                data = fetchFromBases(ASSET_BASES, url)
                if data then
                        local ok, used = writeFile(cachePath, data)
                        if ok then realPath = used end
                end
        end
        if not data or not realPath then return nil, nil end
        local w, h = imageDims(data)
        if hasCustomAsset then
                local ok, uri = pcall(getcustomasset, realPath)
                if ok and type(uri) == "string" then
                        uriCache[cachePath] = uri
                        return uri, w, h
                end
        end
        -- no getcustomasset: return dims only (used by Drawing backend)
        return nil, w, h
end

--==============================================================================
-- FONTS  (Roblox has no TTF loading; approximate each DDLC font)
--==============================================================================
local RFont, DFont
local function firstDrawingFont()
        if hasDrawing and type(Drawing.Fonts) == "table" then
                for _, name in ipairs({ "Plex", "Monaco", "UI", "System" }) do
                        if Drawing.Fonts[name] ~= nil then return Drawing.Fonts[name] end
                end
                for _, v in pairs(Drawing.Fonts) do return v end
        end
        return nil
end
do
        -- Enum.Font values (legacy list, available in every executor)
        local ok, F = pcall(function()
                return {
                        Code = Enum.Font.Code,
                        Nunito = Enum.Font.Nunito,
                        SpecialElite = Enum.Font.SpecialElite,
                        FredokaOne = Enum.Font.FredokaOne,
                        IndieFlower = Enum.Font.IndieFlower,
                        Fondamento = Enum.Font.Fondamento,
                        Bangers = Enum.Font.Bangers,
                        GothamSemibold = Enum.Font.GothamSemibold,
                        Gotham = Enum.Font.Gotham,
                        SourceSans = Enum.Font.SourceSans,
                }
        end)
        if not ok then F = {} end
        RFont = F
        local DF = {}
        if hasDrawing and type(Drawing.Fonts) == "table" then
                DF.Plex = Drawing.Fonts.Plex
                DF.Monaco = Drawing.Fonts.Monaco
                DF.UI = Drawing.Fonts.UI
        end
        DF._fallback = firstDrawingFont()
        DFont = DF
end

local FONT_MAP = {
        ["f25_bank_printer.ttf"] = { rbx = "Code", drw = "Monaco" },      -- console
        ["aller_rg.ttf"] = { rbx = "Nunito", drw = "Plex" },              -- main body
        ["verilyserifmono.ttf"] = { rbx = "SpecialElite", drw = "Monaco" }, -- act 2 "edited"
        ["rifficfree-bold.ttf"] = { rbx = "FredokaOne", drw = "Plex" },   -- names/buttons
        ["m1.ttf"] = { rbx = "IndieFlower", drw = "Plex" },               -- monika poems
        ["y1.ttf"] = { rbx = "Fondamento", drw = "Plex" },                -- yuri poems
        ["y2.ttf"] = { rbx = "Fondamento", drw = "Plex" },
        ["s1.ttf"] = { rbx = "Bangers", drw = "Plex" },                   -- sayori poems
        ["n1.ttf"] = { rbx = "FredokaOne", drw = "Plex" },                -- natsuki poems
        ["halogen.ttf"] = { rbx = "GothamSemibold", drw = "Plex" },       -- poem minigame
}
local function makeFont(path, size)
        local base = tostring(path or ""):lower():match("[^/]+$") or ""
        local info = FONT_MAP[base] or FONT_MAP["aller_rg.ttf"]
        local drw = DFont[info.drw] or DFont._fallback
        return {
                size = size or 24,
                rbx = RFont[info.rbx] or RFont.SourceSans or nil,
                drw = drw,
        }
end

--==============================================================================
-- RENDERER: shared geometry helpers
--==============================================================================
local function computeViewport()
        local vw, vh = GAME_W, GAME_H
        local ok, ws = pcall(function() return workspace.CurrentCamera.ViewportSize end)
        if ok and ws then
                vw, vh = ws.X, ws.Y
        end
        local sc = math.min(vw / GAME_W, vh / GAME_H)
        if sc <= 0 then sc = 1 end
        local offX = (vw - GAME_W * sc) / 2
        local offY = (vh - GAME_H * sc) / 2
        return vw, vh, sc, offX, offY
end

local function toBytes(r, g, b, a)
        if r == nil then r = 255 end
        if g == nil then g = r end
        if b == nil then b = g end
        if a == nil then a = 255 end
        return r, g, b, a
end

--==============================================================================
-- RENDERER BACKEND A: Roblox ScreenGui (preferred; full image + audio support)
--==============================================================================
local GuiRenderer = {}
do
        local okAll, errAll = pcall(function()
                local gui = Instance.new("ScreenGui")
                gui.Name = "DDLC_LOVE_Roblox"
                gui.ResetOnSpawn = false
                gui.IgnoreGuiInset = true
                gui.DisplayOrder = 999999
                local parented = pcall(function() gui.Parent = game:GetService("CoreGui") end)
                if not parented then
                        pcall(function()
                                gui.Parent = game:GetService("Players").LocalPlayer
                                        and game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui", 5)
                                or nil
                        end)
                end

                local black = Instance.new("Frame")       -- letterbox background
                black.BackgroundColor3 = Color3.new(0, 0, 0)
                black.BorderSizePixel = 0
                black.Size = UDim2.fromScale(1, 1)
                black.ZIndex = 0
                black.Parent = gui

                local area = Instance.new("Frame")        -- 1280x720 game area (clipped)
                area.BackgroundColor3 = Color3.new(0, 0, 0)
                area.BorderSizePixel = 0
                area.ClipsDescendants = true
                area.ZIndex = 1
                area.Parent = gui

                -- status overlay
                local statusBg = Instance.new("Frame")
                statusBg.BackgroundColor3 = Color3.new(0, 0, 0)
                statusBg.BackgroundTransparency = 0.25
                statusBg.BorderSizePixel = 0
                statusBg.Position = UDim2.fromOffset(8, 8)
                statusBg.ZIndex = 1000000
                statusBg.Visible = false
                statusBg.Parent = gui
                local statusTx = Instance.new("TextLabel")
                statusTx.BackgroundTransparency = 1
                statusTx.Font = Enum.Font.Gotham
                statusTx.TextSize = 16
                statusTx.TextColor3 = Color3.new(1, 1, 1)
                statusTx.TextXAlignment = Enum.TextXAlignment.Left
                statusTx.TextYAlignment = Enum.TextYAlignment.Top
                statusTx.TextWrapped = true
                statusTx.AutomaticSize = Enum.AutomaticSize.Y
                statusTx.Size = UDim2.fromOffset(580, 16)
                statusTx.Position = UDim2.fromOffset(10, 10)
                statusTx.Parent = statusBg
                statusBg.AutomaticSize = Enum.AutomaticSize.Y
                statusBg.Size = UDim2.fromOffset(600, 0)

                local pool, n = {}, 0
                local vw, vh, sc, offX, offY = GAME_W, GAME_H, 1, 0, 0

                local function newItem(kind, class)
                        n = n + 1
                        local it = pool[n]
                        if it and it.kind == kind and it.inst then
                                it.inst.Visible = true
                                it.inst.ZIndex = n + 1
                                return it
                        end
                        if it and it.inst then pcall(function() it.inst:Destroy() end) end
                        local inst = Instance.new(class)
                        inst.BorderSizePixel = 0
                        inst.Visible = true
                        inst.ZIndex = n + 1
                        inst.Parent = area
                        it = { kind = kind, inst = inst }
                        pool[n] = it
                        return it
                end

                function GuiRenderer.beginFrame()
                        local w, h, s, ox, oy = computeViewport()
                        vw, vh, sc, offX, offY = w, h, s, ox, oy
                        n = 0
                        area.Position = UDim2.fromOffset(math.floor(ox), math.floor(oy))
                        area.Size = UDim2.fromOffset(math.ceil(GAME_W * s), math.ceil(GAME_H * s))
                end

                function GuiRenderer.endFrame()
                        for i = n + 1, #pool do
                                if pool[i].inst then pool[i].inst.Visible = false end
                        end
                end

                local function mapXY(x, y)
                        return offX + x * sc, offY + y * sc
                end

                function GuiRenderer.setBackgroundColor(r, g, b)
                        area.BackgroundColor3 = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                end

                function GuiRenderer.drawImage(img, x, y, sx, sy, r, g, b, a)
                        if img.missing then return end
                        local it = newItem("img", "ImageLabel")
                        local px, py = mapXY(x, y)
                        it.inst.Position = UDim2.fromOffset(px, py)
                        it.inst.Size = UDim2.fromOffset(math.max(1, img.w * sx * sc), math.max(1, img.h * sy * sc))
                        it.inst.Image = img.uri or ""
                        it.inst.ImageColor3 = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                        it.inst.ImageTransparency = 1 - clamp(a / 255, 0, 1)
                        it.inst.BackgroundTransparency = 1
                        it.inst.ScaleType = Enum.ScaleType.Stretch
                end

                local function applyText(inst, text, px, py, font, r, g, b, a, wrapped, limit, align)
                        inst.Text = tostring(text)
                        inst.TextColor3 = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                        inst.TextTransparency = 1 - clamp(a / 255, 0, 1)
                        inst.Font = font.rbx or Enum.Font.SourceSans
                        inst.TextSize = clamp(math.floor((font.size or 24) * sc + 0.5), 1, 100)
                        inst.TextXAlignment = align or Enum.TextXAlignment.Left
                        inst.TextWrapped = wrapped
                        inst.RichText = false
                        inst.Position = UDim2.fromOffset(px, py)
                        if wrapped then
                                inst.AutomaticSize = Enum.AutomaticSize.Y
                                inst.Size = UDim2.fromOffset(math.max(1, math.floor(limit * sc)), 0)
                        else
                                inst.AutomaticSize = Enum.AutomaticSize.XY
                                inst.Size = UDim2.fromOffset(0, 0)
                        end
                end

                function GuiRenderer.drawStrokedText(text, x, y, font, r, g, b, a, sr, sg, sb, sa)
                        local it = newItem("txts", "TextLabel")
                        it.inst.BackgroundTransparency = 1
                        local px, py = mapXY(x, y)
                        applyText(it.inst, text, px, py, font, r, g, b, a, false)
                        if not it.stroke then
                                local st = Instance.new("UIStroke")
                                st.Thickness = 1.6
                                st.Parent = it.inst
                                it.stroke = st
                        end
                        it.stroke.Color = Color3.new(clamp(sr / 255, 0, 1), clamp(sg / 255, 0, 1), clamp(sb / 255, 0, 1))
                        it.stroke.Transparency = 1 - clamp(sa / 255, 0, 1)
                        it.stroke.Enabled = true
                end

                function GuiRenderer.drawText(text, x, y, font, r, g, b, a)
                        local it = newItem("txt", "TextLabel")
                        it.inst.BackgroundTransparency = 1
                        local px, py = mapXY(x, y)
                        applyText(it.inst, text, px, py, font, r, g, b, a, false)
                end

                function GuiRenderer.drawTextWrapped(text, x, y, limit, align, font, r, g, b, a)
                        local it = newItem("txtw", "TextLabel")
                        it.inst.BackgroundTransparency = 1
                        local px, py = mapXY(x, y)
                        local al = Enum.TextXAlignment.Left
                        if align == "center" then al = Enum.TextXAlignment.Center
                        elseif align == "right" then al = Enum.TextXAlignment.Right end
                        applyText(it.inst, text, px, py, font, r, g, b, a, true, limit, al)
                end

                function GuiRenderer.drawRect(mode, x, y, w, h, r, g, b, a)
                        local it = newItem("rect", "Frame")
                        local px, py = mapXY(x, y)
                        it.inst.Position = UDim2.fromOffset(px, py)
                        it.inst.Size = UDim2.fromOffset(math.max(1, w * sc), math.max(1, h * sc))
                        it.inst.BackgroundColor3 = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                        it.inst.BackgroundTransparency = 1 - clamp(a / 255, 0, 1)
                        it.inst.BorderSizePixel = 0
                        if mode == "line" then
                                it.inst.BackgroundTransparency = 1
                                if not it.stroke then
                                        local st = Instance.new("UIStroke")
                                        st.Thickness = 1
                                        st.Parent = it.inst
                                        it.stroke = st
                                end
                                it.stroke.Color = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                                it.stroke.Transparency = 1 - clamp(a / 255, 0, 1)
                                it.stroke.Enabled = true
                        elseif it.stroke then
                                it.stroke.Enabled = false
                        end
                end

                function GuiRenderer.measureText(text, font)
                        -- approximate width (used rarely; only for Drawing-style fallbacks)
                        local size = (font.size or 24) * sc
                        return #tostring(text) * size * 0.5, size
                end

                function GuiRenderer.setStatus(msg)
                        if msg == "" then
                                statusBg.Visible = false
                                return
                        end
                        statusBg.Visible = true
                        statusTx.Text = msg
                end

                function GuiRenderer.getGui()
                        return gui
                end

                function GuiRenderer.destroy()
                        pcall(function() gui:Destroy() end)
                end

                GuiRenderer.works = true
        end)
        if not okAll then
                GuiRenderer.works = false
                GuiRenderer.initError = errAll
                function GuiRenderer.destroy() end
        end
end

--==============================================================================
-- RENDERER BACKEND B: Drawing API (fallback; URL images, no audio)
--==============================================================================
local DrawRenderer = {}
do
        local okAll, errAll = pcall(function()
                local frameObjects = {}
                local bgSquare = Drawing.new("Square")
                bgSquare.Filled = true
                bgSquare.Color = Color3.new(0, 0, 0)
                bgSquare.Thickness = 0
                pcall(function() bgSquare.ZIndex = -100000 end)

                local statusText = Drawing.new("Text")
                statusText.Visible = false
                statusText.Size = 16
                statusText.Color = Color3.new(1, 1, 1)
                statusText.Outline = true
                pcall(function() statusText.Font = Drawing.Fonts.Plex end)
                pcall(function() statusText.ZIndex = 100000 end)

                local vw, vh, sc, offX, offY = GAME_W, GAME_H, 1, 0, 0
                local z = 0

                local function newObj(class)
                        local o = Drawing.new(class)
                        o.Visible = true
                        z = z + 1
                        pcall(function() o.ZIndex = z end)
                        frameObjects[#frameObjects + 1] = o
                        return o
                end

                function DrawRenderer.beginFrame()
                        for i = 1, #frameObjects do
                                pcall(function() frameObjects[i]:Remove() end)
                        end
                        frameObjects = {}
                        local w, h, s, ox, oy = computeViewport()
                        vw, vh, sc, offX, offY = w, h, s, ox, oy
                        bgSquare.Position = Vector2.new(0, 0)
                        bgSquare.Size = Vector2.new(w, h)
                        z = 0
                end

                function DrawRenderer.endFrame() end

                local function mapXY(x, y)
                        return offX + x * sc, offY + y * sc
                end

                function DrawRenderer.setBackgroundColor(r, g, b)
                        bgSquare.Color = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                end

                function DrawRenderer.drawImage(img, x, y, sx, sy, r, g, b, a)
                        if img.missing then return end
                        local o = newObj("Image")
                        local px, py = mapXY(x, y)
                        o.Position = Vector2.new(px, py)
                        o.Size = Vector2.new(math.max(1, img.w * sx * sc), math.max(1, img.h * sy * sc))
                        o.Color = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                        o.Transparency = 1 - clamp(a / 255, 0, 1)
                        o.Image = img.url or ""
                end

                local function lineY(font)
                        return (font.size or 24) * sc * 1.35
                end

                function DrawRenderer.drawText(text, x, y, font, r, g, b, a)
                        text = tostring(text)
                        local px, py = mapXY(x, y)
                        local lh = lineY(font)
                        local i = 0
                        for line in (text .. "\n"):gmatch("(.-)\n") do
                                local o = newObj("Text")
                                o.Text = line
                                o.Position = Vector2.new(px, py + i * lh)
                                o.Size = clamp(math.floor((font.size or 24) * sc + 0.5), 1, 1000)
                                o.Color = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                                o.Transparency = 1 - clamp(a / 255, 0, 1)
                                o.Outline = true
                                o.Center = false
                                if font.drw then o.Font = font.drw end
                                i = i + 1
                        end
                end

                -- measure via a temporary text object
                local measureObj
                local function measureWidth(text, font)
                        if not measureObj then measureObj = Drawing.new("Text") end
                        measureObj.Text = text
                        measureObj.Size = clamp(math.floor((font.size or 24) * sc + 0.5), 1, 1000)
                        if font.drw then measureObj.Font = font.drw end
                        local ok, b = pcall(function() return measureObj.TextBounds end)
                        if ok and b then return b.X end
                        return #text * (font.size or 24) * sc * 0.55
                end

                function DrawRenderer.drawTextWrapped(text, x, y, limit, align, font, r, g, b, a)
                        text = tostring(text)
                        local px, py = mapXY(x, y)
                        local lim = limit * sc
                        local lh = lineY(font)
                        local line = ""
                        local lineW = 0
                        local row = 0
                        local spaceW = measureWidth(" ", font)
                        local function emit(str)
                                local w = measureWidth(str, font)
                                local ox = px
                                if align == "center" then ox = px + (lim - w) / 2
                                elseif align == "right" then ox = px + lim - w end
                                local o = newObj("Text")
                                o.Text = str
                                o.Position = Vector2.new(ox, py + row * lh)
                                o.Size = clamp(math.floor((font.size or 24) * sc + 0.5), 1, 1000)
                                o.Color = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                                o.Transparency = 1 - clamp(a / 255, 0, 1)
                                o.Outline = true
                                o.Center = false
                                if font.drw then o.Font = font.drw end
                                row = row + 1
                        end
                        for para in (text .. "\n"):gmatch("(.-)\n") do
                                if para == "" then
                                        row = row + 1
                                else
                                        for word in para:gmatch("%S+") do
                                                local ww = measureWidth(word, font)
                                                if line ~= "" and lineW + spaceW + ww > lim then
                                                        emit(line)
                                                        line, lineW = word, ww
                                                else
                                                        if line == "" then
                                                                line, lineW = word, ww
                                                        else
                                                                line = line .. " " .. word
                                                                lineW = lineW + spaceW + ww
                                                        end
                                                end
                                        end
                                        if line ~= "" then emit(line) line, lineW = "", 0 end
                                end
                        end
                end

                function DrawRenderer.drawRect(mode, x, y, w, h, r, g, b, a)
                        if mode == "line" then
                                local t = 1
                                DrawRenderer.drawRect("fill", x, y, w, t, r, g, b, a)
                                DrawRenderer.drawRect("fill", x, y + h - t, w, t, r, g, b, a)
                                DrawRenderer.drawRect("fill", x, y, t, h, r, g, b, a)
                                DrawRenderer.drawRect("fill", x + w - t, y, t, h, r, g, b, a)
                                return
                        end
                        local o = newObj("Square")
                        local px, py = mapXY(x, y)
                        o.Position = Vector2.new(px, py)
                        o.Size = Vector2.new(math.max(1, w * sc), math.max(1, h * sc))
                        o.Color = Color3.new(clamp(r / 255, 0, 1), clamp(g / 255, 0, 1), clamp(b / 255, 0, 1))
                        o.Transparency = 1 - clamp(a / 255, 0, 1)
                        o.Filled = true
                        o.Thickness = 1
                end

                function DrawRenderer.measureText(text, font)
                        local w = measureWidth(tostring(text), font)
                        return w, (font.size or 24) * sc
                end

                function DrawRenderer.setStatus(msg)
                        if msg == "" then
                                statusText.Visible = false
                                return
                        end
                        statusText.Visible = true
                        statusText.Text = msg
                        statusText.Position = Vector2.new(8, 8)
                end

                function DrawRenderer.destroy()
                        for i = 1, #frameObjects do pcall(function() frameObjects[i]:Remove() end) end
                        pcall(function() bgSquare:Remove() end)
                        pcall(function() statusText:Remove() end)
                        if measureObj then pcall(function() measureObj:Remove() end) end
                end

                DrawRenderer.works = true
        end)
        if not okAll then
                DrawRenderer.works = false
                DrawRenderer.initError = errAll
                function DrawRenderer.destroy() end
        end
end

--==============================================================================
-- PICK BACKEND
--==============================================================================
local Renderer
local backendName
if GuiRenderer.works and hasCustomAsset and hasWrite and hasNetwork then
        Renderer, backendName = GuiRenderer, "gui"
elseif DrawRenderer.works and hasNetwork then
        Renderer, backendName = DrawRenderer, "drawing"
elseif GuiRenderer.works then
        Renderer, backendName = GuiRenderer, "gui-textonly"
        warnOnce("No getcustomasset/writefile available - images disabled, text-only mode.")
else
        error("[DDLC-LOVE] Neither the Roblox GUI nor the Drawing API is available in this environment.", 0)
end

--==============================================================================
-- PSEUDO GUI IMAGES (menu buttons native to Roblox, since the language button
-- sheets are not part of the public assets repo)
--==============================================================================
local PSEUDO_WHITE = { 240, 240, 240 }
local PSEUDO_PINK = { 168, 72, 144 }

local PSEUDO_TEXT = {
        eng = {
                mainbuttons = { "Load Game", "Settings", "Help", "Quit" },
                gamebuttons = { "History", "Save Game", "Load Game", "Main Menu", "Settings", "Help", "Quit", "Return" },
                newgame = "New Game",
                newgame1 = "New Game",
                gamemenu = { "Game", "Menu" },
                history = "History",
                load = "Load",
                save = "Save",
                settings = "Settings",
                setbuttons = {
                        { "Text Speed", 371, 344 }, { "Auto-Forward Time", 371, 411 },
                        { "Characters", 371, 479 }, { "Language", 371, 548 },
                        { "Master Volume", 818, 344 }, { "Music Volume", 818, 411 },
                        { "Sound Volume", 818, 479 },
                },
        },
        spa = {
                mainbuttons = { "Cargar partida", "Ajustes", "Ayuda", "Salir" },
                gamebuttons = { "Historial", "Guardar partida", "Cargar partida", "Menú principal", "Ajustes", "Ayuda", "Salir", "Volver" },
                newgame = "Nueva partida",
                newgame1 = "Nueva partida",
                gamemenu = { "Menú", "de juego" },
                history = "Historial",
                load = "Cargar",
                save = "Guardar",
                settings = "Ajustes",
                setbuttons = {
                        { "Text Speed", 371, 344 }, { "Auto-Forward Time", 371, 411 },
                        { "Characters", 371, 479 }, { "Language", 371, 548 },
                        { "Master Volume", 818, 344 }, { "Music Volume", 818, 411 },
                        { "Sound Volume", 818, 479 },
                },
        },
}

local function drawStrokedText(text, x, y, size, mainColor)
        local font = { size = size, rbx = RFont.FredokaOne, drw = DFont.Plex }
        if Renderer.drawStrokedText then
                Renderer.drawStrokedText(text, x, y, font,
                        mainColor[1], mainColor[2], mainColor[3], 255,
                        PSEUDO_PINK[1], PSEUDO_PINK[2], PSEUDO_PINK[3], 255)
        else
                local off = 1.5
                for _, d in ipairs({ { -off, 0 }, { off, 0 }, { 0, -off }, { 0, off } }) do
                        Renderer.drawText(text, x + d[1], y + d[2], font,
                                PSEUDO_PINK[1], PSEUDO_PINK[2], PSEUDO_PINK[3], 255)
                end
                Renderer.drawText(text, x, y, font, mainColor[1], mainColor[2], mainColor[3], 255)
        end
end

local function drawPseudoImage(p, x, y)
        local lang = PSEUDO_TEXT[p.lang] and p.lang or "eng"
        local T = PSEUDO_TEXT[lang]
        local name = p.name
        if name == "mainbuttons" or name == "gamebuttons" then
                local labels = T[name]
                local y0 = (name == "mainbuttons") and 457 or 373
                for i = 1, #labels do
                        drawStrokedText(labels[i], x + 85, y0 + (i - 1) * 42, 26, PSEUDO_WHITE)
                end
        elseif name == "newgame" or name == "newgame1" then
                local label = T[name]
                drawStrokedText(label, x + 85, y + 416, 26, PSEUDO_WHITE)
                if name == "newgame1" then
                        -- glitchy strike-through variant (act 2 title screen)
                        Renderer.drawRect("fill", x + 85, y + 426, 118, 3, 168, 72, 144, 255)
                end
        elseif name == "gamemenu" then
                for i = 1, #T.gamemenu do
                        drawStrokedText(T.gamemenu[i], x + 51, y + 35 + (i - 1) * 45, 34, PSEUDO_WHITE)
                end
        elseif name == "history" or name == "load" or name == "save" or name == "settings" then
                drawStrokedText(T[name], x + 51, y + 37, 44, PSEUDO_WHITE)
        elseif name == "setbuttons" then
                for i = 1, #T.setbuttons do
                        local it = T.setbuttons[i]
                        drawStrokedText(it[1], x + it[2], y + it[3], 24, PSEUDO_WHITE)
                end
        end
end

--==============================================================================
-- SOUND SUPPORT
--==============================================================================
local allSounds = {}
local function stopAllSounds()
        for i = 1, #allSounds do
                pcall(function() allSounds[i]:Stop() end)
        end
end

local SILENT_SOURCE
do
        SILENT_SOURCE = {
                silent = true,
                play = function() end,
                stop = function() end,
                isPlaying = function() return false end,
                setVolume = function() end,
                getVolume = function() return 0 end,
                setLooping = function() end,
                getLooping = function() return false end,
                clone = function() return SILENT_SOURCE end,
        }
end

local soundParent
do
        local ok = pcall(function()
                soundParent = Instance.new("Folder")
                soundParent.Name = "DDLC_LOVE_Sounds"
                soundParent.Parent = game:GetService("SoundService")
        end)
        if not ok then
                pcall(function()
                        soundParent = Instance.new("Folder")
                        soundParent.Name = "DDLC_LOVE_Sounds"
                        soundParent.Parent = workspace
                end)
        end
end

local function wrapSound(snd)
        local w = {
                play = function() pcall(function() snd:Play() end) end,
                stop = function() pcall(function() snd:Stop() end) end,
                isPlaying = function() return snd.IsPlaying == true end,
                setVolume = function(v) pcall(function() snd.Volume = clamp(tonumber(v) or 1, 0, 10) end) end,
                getVolume = function() local v = snd.Volume return tonumber(v) or 0 end,
                setLooping = function(b) pcall(function() snd.Looped = b and true or false end) end,
                getLooping = function() return snd.Looped == true end,
                clone = function()
                        local c
                        pcall(function()
                                c = snd:Clone()
                                c.Parent = soundParent
                        end)
                        if not c then return SILENT_SOURCE end
                        allSounds[#allSounds + 1] = c
                        return wrapSound(c)
                end,
        }
        return w
end

local function newSoundSource(path)
        if not hasCustomAsset or not soundParent then return SILENT_SOURCE end
        local rel, _ext = mapAssetURL(path)
        if not rel then return SILENT_SOURCE end
        local uri = getAssetURI(rel)
        if not uri then
                warnOnce("audio unavailable: " .. path)
                return SILENT_SOURCE
        end
        local ok, snd = pcall(function()
                local s = Instance.new("Sound")
                s.SoundId = uri
                s.Volume = 1
                s.Parent = soundParent
                return s
        end)
        if not ok or not snd then return SILENT_SOURCE end
        allSounds[#allSounds + 1] = snd
        return wrapSound(snd)
end

--==============================================================================
-- GAME FILE ACCESS  (love.filesystem + require)
--==============================================================================
local CODE_FILES = {
        ["main.lua"] = true, ["menu.lua"] = true, ["draw.lua"] = true, ["saveload.lua"] = true,
        ["keyboard.lua"] = true, ["cindy.lua"] = true, ["conf.lua"] = true,
}
local CODE_PREFIXES = { "loader/", "states/", "scripts/" }

local function isGameCodePath(name)
        if type(name) ~= "string" then return false end
        if name:sub(-4) ~= ".lua" then return false end
        if CODE_FILES[name] then return true end
        for i = 1, #CODE_PREFIXES do
                if name:sub(1, #CODE_PREFIXES[i]) == CODE_PREFIXES[i] then return true end
        end
        return false
end

local function fsRead(name)
        if type(name) ~= "string" or name == "" then return nil end
        -- 1) on-disk (saves, settings, cached game code)
        if isFile(SAVE_DIR .. name) then
                return readFile(SAVE_DIR .. name)
        end
        -- 2) game code from the DDLC-LOVE repository (then cached to disk)
        if isGameCodePath(name) then
                local body = fetchFromBases(CODE_BASES, name)
                if body then
                        writeFile(SAVE_DIR .. name, body)
                        return body
                end
                return nil
        end
        -- 3) assets: report existence without downloading (lg.newImage downloads)
        if manifest[name] then
                return "1"
        end
        return nil
end

--==============================================================================
-- THE LÖVE SHIM
--==============================================================================
love = {}

-- filesystem -------------------------------------------------------------------
love.filesystem = {}
function love.filesystem.read(name)
        return fsRead(name)
end
function love.filesystem.write(name, data)
        return writeFile(SAVE_DIR .. tostring(name), tostring(data or ""))
end
function love.filesystem.append(name, data)
        return appendFileData(SAVE_DIR .. tostring(name), tostring(data or ""))
end
function love.filesystem.load(name)
        local content = fsRead(name)
        if not content then return nil end
        return loadstring(content, "@" .. tostring(name))
end
function love.filesystem.getInfo(name)
        if fsRead(name) then return { size = 1 } end
        return nil
end
function love.filesystem.getSaveDirectory()
        return SAVE_DIR
end

love._console_name = nil
love._version_string = "DDLC-LOVE Roblox Shim"

function love.getVersion()
        return 0, 10, 2, "Roblox"
end

-- graphics -------------------------------------------------------------------
love.graphics = {}
local LG = love.graphics
lg = LG

local curColor = { 255, 255, 255, 255 }
local curFont = makeFont("assets/fonts/Aller_Rg.ttf", 24)
local transform = { sx = 1, sy = 1 }
local transformStack = {}

local function colBytes(r, g, b, a)
        r, g, b, a = toBytes(r, g, b, a)
        curColor[1], curColor[2], curColor[3], curColor[4] = r, g, b, a
        return r, g, b, a
end

function LG.setColor(r, g, b, a) colBytes(r, g, b, a) end
function LG.getColor() return curColor[1], curColor[2], curColor[3], curColor[4] end
function LG.setBackgroundColor(r, g, b)
        r, g, b = toBytes(r, g, b)
        Renderer.setBackgroundColor(r, g, b)
end
function LG.getBackgroundColor() return 0, 0, 0 end
function LG.clear() end
function LG.origin() transform.sx, transform.sy = 1, 1 end
function LG.push() transformStack[#transformStack + 1] = { sx = transform.sx, sy = transform.sy } end
function LG.pop()
        local t = transformStack[#transformStack]
        if t then
                transformStack[#transformStack] = nil
                transform.sx, transform.sy = t.sx, t.sy
        end
end
function LG.scale(sx, sy)
        sx = sx or 1
        sy = sy or sx
        transform.sx = transform.sx * sx
        transform.sy = transform.sy * sy
end

function LG.newFont(path, size)
        return makeFont(path, size)
end

function LG.setFont(f)
        curFont = f or makeFont("assets/fonts/Aller_Rg.ttf", 24)
end

function LG.getFont() return curFont end

function LG.newImage(path)
        local pseudo = PSEUDO[path]
        if pseudo then
                return { pseudo = pseudo, w = 1280, h = 720 }
        end
        local rel, _ext = mapAssetURL(path)
        if not rel then
                return { missing = true, w = 1, h = 1 }
        end
        local uri, w, h = getAssetURI(rel)
        if not uri and not w then
                warnOnce("image unavailable: " .. path)
                return { missing = true, w = 1, h = 1 }
        end
        return {
                url = ASSET_BASES[1] .. "/" .. rel,
                uri = uri,
                w = w or 1,
                h = h or 1,
        }
end

local function normText(text)
        if text == nil then text = "" end
        text = tostring(text)
        text = text:gsub("\t", "   ")
        return text
end

function LG.draw(drawable, x, y, r, sx, sy)
        if drawable == nil then return end
        x = x or 0
        y = y or 0
        if drawable.pseudo then
                local cr, cg, cb, ca = colBytes()
                drawPseudoImage(drawable.pseudo, x * transform.sx, y * transform.sy)
                return
        end
        r = r or 0
        if sx == nil and sy == nil then
                sx, sy = 1, 1
        elseif sy == nil then
                sy = sx
        end
        if sx == 0 then sx = 1 end
        if sy == 0 then sy = 1 end
        local cr, cg, cb, ca = colBytes()
        Renderer.drawImage(drawable,
                x * transform.sx, y * transform.sy,
                sx * transform.sx, sy * transform.sy,
                cr, cg, cb, ca)
end

function LG.print(text, x, y)
        x = x or 0
        y = y or 0
        local cr, cg, cb, ca = colBytes()
        Renderer.drawText(normText(text), x * transform.sx, y * transform.sy, curFont, cr, cg, cb, ca)
end

function LG.printf(text, x, y, limit, align)
        x = x or 0
        y = y or 0
        limit = limit or GAME_W
        local cr, cg, cb, ca = colBytes()
        Renderer.drawTextWrapped(normText(text), x * transform.sx, y * transform.sy,
                limit * transform.sx, align, curFont, cr, cg, cb, ca)
end

function LG.rectangle(mode, x, y, w, h)
        local cr, cg, cb, ca = colBytes()
        Renderer.drawRect(mode, x * transform.sx, y * transform.sy,
                w * transform.sx, h * transform.sy, cr, cg, cb, ca)
end

LG.set3D = nil -- 3DS only; pcall-guarded in the game

-- audio -----------------------------------------------------------------------
love.audio = {}
function love.audio.newSource(path, _sourcetype)
        return newSoundSource(path)
end
function love.audio.play(src)
        if src and src.play then src:play() end
end
function love.audio.stop(src)
        if src and src.stop then src:stop() end
end

-- math ------------------------------------------------------------------------
love.math = {}
function love.math.random(a, b)
        if a == nil then return math.random()
        elseif b == nil then return math.random(a)
        else return math.random(a, b) end
end
function love.math.setRandomSeed(s)
        math.randomseed(tonumber(s) or os.time())
end
love.math.randomNormal = function() return math.random() end

-- timer -----------------------------------------------------------------------
love.timer = {}
local lastDt = 0
function love.timer.getDelta() return lastDt end
function love.timer.getTime() return os.clock() end
function love.timer.sleep() end

-- keyboard --------------------------------------------------------------------
love.keyboard = {}
local keyStates = {}
function love.keyboard.isDown(k)
        return keyStates[k] == true
end
function love.keyboard.setTextInput() end
function love.keyboard.hasTextInput() return false end

-- system ----------------------------------------------------------------------
love.system = {}
function love.system.getOS() return "Windows" end

-- window ----------------------------------------------------------------------
love.window = {}
function love.window.setTitle() end
function love.window.setMode() return true end
function love.window.setFullscreen() return false end
function love.window.getDesktopDimensions()
        local vw, vh = computeViewport()
        return vw, vh
end

-- event -----------------------------------------------------------------------
love.event = {}
local quitHandler = nil
function love.event.quit()
        if quitHandler then quitHandler() end
end

-- joystick --------------------------------------------------------------------
love.joystick = {}
function love.joystick.getJoysticks() return {} end

--==============================================================================
-- require() LOADER (fetches game modules, caches like LÖVE require)
--==============================================================================
local loadedModules = {}
function require(name)
        local key = tostring(name)
        if loadedModules[key] ~= nil then return loadedModules[key] end
        local path = key
        if path:sub(-4) ~= ".lua" then path = path .. ".lua" end
        local src = fsRead(path)
        if not src then
                error("DDLC-LOVE module not found: " .. key, 2)
        end
        local chunk, err = loadstring(src, "@" .. path)
        if not chunk then error("DDLC-LOVE module parse error in " .. path .. ": " .. tostring(err), 2) end
        local ret = chunk()
        loadedModules[key] = (ret ~= nil) and ret or true
        return loadedModules[key]
end

--==============================================================================
-- os.date SHIM (Roblox lacks a formatting os.date in some environments)
--==============================================================================
do
        local ok = pcall(function() return os.date("%Y-%m-%d %H:%M") end)
        if not ok or type(os.date("%Y-%m-%d %H:%M")) ~= "string" then
                local function civilFromDays(z)
                        z = z + 719468
                        local era = math.floor(z / 146097)
                        local doe = z - era * 146097
                        local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
                                - math.floor(doe / 146096)) / 365)
                        local y = yoe + era * 400
                        local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
                        local mp = math.floor((5 * doy + 2) / 153)
                        local d = doy - math.floor((153 * mp + 2) / 5) + 1
                        local m = mp + (mp < 10 and 3 or -9)
                        return y + (m <= 2 and 1 or 0), m, d
                end
                os.date = function(fmt)
                        fmt = fmt or "%Y-%m-%d %H:%M"
                        if fmt == "*t" then
                                local t = os.time()
                                local days = math.floor(t / 86400)
                                local y, mo, d = civilFromDays(days)
                                local secs = t % 86400
                                return { year = y, month = mo, day = d, hour = math.floor(secs / 3600),
                                        min = math.floor(secs / 60) % 60, sec = secs % 60 }
                        end
                        local t = os.time()
                        local days = math.floor(t / 86400)
                        local y, mo, d = civilFromDays(days)
                        local secs = t % 86400
                        local hh = fmt("%02d", math.floor(secs / 3600))
                        local mi = fmt("%02d", math.floor(secs / 60) % 60)
                        return (fmt:gsub("%%Y", fmt("%04d", y)):gsub("%%m", fmt("%02d", mo))
                                :gsub("%%d", fmt("%02d", d)):gsub("%%H", hh):gsub("%%M", mi))
                end
        end
end

--==============================================================================
-- INPUT (keyboard + touch)
--==============================================================================
local connections = {}
local function connect(sig, fn)
        local ok, c = pcall(function() return sig:Connect(fn) end)
        if ok and c then connections[#connections + 1] = c end
        return c
end

local function fireKey(name)
        if love.keypressed then
                pcall(love.keypressed, name)
        end
end

do
        local UIS = game:GetService("UserInputService")
        local KEYMAP = {}
        if Enum and Enum.KeyCode then
                local KC = Enum.KeyCode
                KEYMAP[KC.Space] = "space"
                KEYMAP[KC.Return] = "return"
                KEYMAP[KC.Escape] = "escape"
                KEYMAP[KC.Backspace] = "backspace"
                KEYMAP[KC.Up] = "up"
                KEYMAP[KC.Down] = "down"
                KEYMAP[KC.Left] = "left"
                KEYMAP[KC.Right] = "right"
                KEYMAP[KC.One] = "1"
                KEYMAP[KC.Two] = "2"
                KEYMAP[KC.Three] = "3"
                KEYMAP[KC.Four] = "4"
                KEYMAP[KC.LeftShift] = "lshift"
                KEYMAP[KC.RightShift] = "rshift"
        end
        connect(UIS.InputBegan, function(input, gp)
                if gp then return end
                local name = KEYMAP[input.KeyCode]
                if name then
                        keyStates[name] = true
                        fireKey(name)
                elseif backendName == "drawing"
                        and input.UserInputType == Enum.UserInputType.Touch then
                        fireKey("space") -- tap anywhere advances (Drawing backend)
                end
        end)
        connect(UIS.InputEnded, function(input)
                local name = KEYMAP[input.KeyCode]
                if name then keyStates[name] = false end
        end)
end

-- touch pad + tap-to-advance (GUI backend) -------------------------------------
do
        if backendName ~= "drawing" and Renderer.getGui then
                local gui = Renderer.getGui()
                local touchOk, touchEnabled = pcall(function() return game:GetService("UserInputService").TouchEnabled end)

                local function bindButton(btn, keyName)
                        connect(btn.InputBegan, function(io)
                                if io.UserInputType == Enum.UserInputType.Touch
                                        or io.UserInputType == Enum.UserInputType.MouseButton1 then
                                        keyStates[keyName] = true
                                        fireKey(keyName)
                                end
                        end)
                        connect(btn.InputEnded, function(io)
                                if io.UserInputType == Enum.UserInputType.Touch
                                        or io.UserInputType == Enum.UserInputType.MouseButton1 then
                                        keyStates[keyName] = false
                                end
                        end)
                end

                -- fullscreen tap catcher (advance / confirm)
                local catcher = Instance.new("TextButton")
                catcher.Name = "DDLC_TapCatcher"
                catcher.BackgroundTransparency = 1
                catcher.Text = ""
                catcher.AutoButtonColor = false
                catcher.Size = UDim2.fromScale(1, 1)
                catcher.ZIndex = 900000
                catcher.Parent = gui
                bindButton(catcher, "space")

                if touchOk and touchEnabled then
                        local pad = Instance.new("Frame")
                        pad.BackgroundTransparency = 1
                        pad.Size = UDim2.fromScale(1, 1)
                        pad.ZIndex = 950000
                        pad.Parent = gui

                        local function mkBtn(text, x, y, w, h, keyName, textSize)
                                local b = Instance.new("TextButton")
                                b.BackgroundColor3 = Color3.new(0, 0, 0)
                                b.BackgroundTransparency = 0.45
                                b.TextColor3 = Color3.new(1, 1, 1)
                                b.Font = Enum.Font.GothamBold
                                b.TextSize = textSize or 18
                                b.Text = text
                                b.AutoButtonColor = false
                                b.BorderSizePixel = 0
                                b.Position = UDim2.fromOffset(x, y)
                                b.Size = UDim2.fromOffset(w, h)
                                b.ZIndex = 950001
                                b.Parent = pad
                                local corner = Instance.new("UICorner")
                                corner.CornerRadius = UDim.new(0, 10)
                                corner.Parent = b
                                bindButton(b, keyName)
                                return b
                        end

                        local padBtns = {}
                        local function layoutPad()
                                local vw, vh = computeViewport()
                                local m = 18
                                local s = 56
                                padBtns.up = mkBtn("\226\150\178", m + s, vh - m - 3 * s, s, s, "up")          -- ▲
                                padBtns.left = mkBtn("\226\151\132", m, vh - m - 2 * s, s, s, "left")          -- ◀
                                padBtns.right = mkBtn("\226\150\186", m + 2 * s, vh - m - 2 * s, s, s, "right") -- ▶
                                padBtns.down = mkBtn("\226\150\190", m + s, vh - m - s, s, s, "down")          -- ▼
                                padBtns.a = mkBtn("A", vw - m - 74, vh - m - 74, 74, 74, "space", 26)
                                padBtns.b = mkBtn("B", vw - m - 160, vh - m - 52, 52, 52, "escape", 22)
                                padBtns.menu = mkBtn("MENU", vw - m - 60, m + 96, 60, 40, "1", 14)
                                padBtns.skip = mkBtn("SKIP", vw - m - 130, m + 96, 64, 40, "2", 14)
                                padBtns.auto = mkBtn("AUTO", vw - m - 202, m + 96, 66, 40, "3", 14)
                        end
                        layoutPad()
                        session.relayoutPad = layoutPad
                end
        end
end

--==============================================================================
-- MAIN LOOP
--==============================================================================
local running = true
local consecErrors = 0
local hbConn
local lastVw, lastVh

local function setStatus(msg)
        Renderer.setStatus(msg)
        mkstatus(msg)
end

local function handleError(where, err)
        consecErrors = consecErrors + 1
        warn_("[DDLC-LOVE] " .. where .. " error: " .. tostring(err))
        if consecErrors >= 3 then
                setStatus("[DDLC-LOVE] " .. where .. " error: " .. tostring(err) .. "  (x" .. consecErrors .. ")")
        end
        if consecErrors >= 150 then
                running = false
                setStatus("[DDLC-LOVE] Stopped after repeated errors: " .. tostring(err)
                        .. "  |  Re-run the script to retry.")
        end
end

local function step(dt)
        if not running then return end
        lastDt = dt
        if love.update then
                local ok, err = pcall(love.update, dt)
                if not ok then handleError("update", err) return end
        end
        Renderer.beginFrame()
        if love.draw then
                local ok, err = pcall(love.draw)
                if not ok then
                        Renderer.endFrame()
                        handleError("draw", err)
                        return
                end
        end
        Renderer.endFrame()
        if consecErrors > 0 and consecErrors < 3 then consecErrors = 0 end
        if consecErrors == 0 then setStatus("") end
        -- keep touch pad on screen when viewport changes
        if session.relayoutPad then
                local vw, vh = computeViewport()
                if vw ~= lastVw or vh ~= lastVh then
                        lastVw, lastVh = vw, vh
                        pcall(session.relayoutPad)
                end
        end
end

local function quitGame()
        running = false
        stopAllSounds()
        if hbConn then pcall(function() hbConn:Disconnect() end) end
        setStatus("DDLC-LOVE has finished.\nRe-run the script to play again (your saves are kept).")
end
quitHandler = quitGame

local function destroy()
        running = false
        if hbConn then pcall(function() hbConn:Disconnect() end) end
        for i = 1, #connections do pcall(function() connections[i]:Disconnect() end) end
        stopAllSounds()
        for i = 1, #allSounds do pcall(function() allSounds[i]:Destroy() end) end
        Renderer.destroy()
end
session.destroy = destroy
session.step = step
session.fireKey = fireKey
session.love = love
session.keyStates = keyStates
session.backend = backendName

--==============================================================================
-- BOOT
--==============================================================================
local function boot()
        setStatus("DDLC-LOVE (Roblox port)\nDownloading game files (first run only)...")
        local src = fsRead("main.lua")
        if not src then
                setStatus("[DDLC-LOVE] Could not download main.lua.\n"
                        .. "Check your internet connection / executor HTTP access.")
                error("[DDLC-LOVE] could not fetch main.lua", 0)
        end
        local chunk, err = loadstring(src, "@main.lua")
        if not chunk then
                setStatus("[DDLC-LOVE] main.lua parse error: " .. tostring(err))
                error("[DDLC-LOVE] main.lua parse error: " .. tostring(err), 0)
        end
        local ok, berr = pcall(chunk)
        if not ok then
                setStatus("[DDLC-LOVE] boot error: " .. tostring(berr))
                error("[DDLC-LOVE] boot error: " .. tostring(berr), 0)
        end
        if love.load then
                local ok2, lerr = pcall(love.load)
                if not ok2 then
                        setStatus("[DDLC-LOVE] love.load error: " .. tostring(lerr))
                        error("[DDLC-LOVE] love.load error: " .. tostring(lerr), 0)
                end
        end
        setStatus("")
        -- start the frame loop
        local RunService = game:GetService("RunService")
        local okc, conn = pcall(function() return RunService.Heartbeat:Connect(step) end)
        if okc and conn then hbConn = conn else step(1 / 60) end
        print_("[DDLC-LOVE] Roblox port ready. backend=" .. backendName
                .. "  saves: workspace/" .. SAVE_DIR)
end

boot()
