local Screen = require "widgets/screen"
local Widget = require "widgets/widget"
local Text = require "widgets/text"
local TEMPLATES = require "widgets/redux/templates"

local AIConfigScreen = Class(Screen, function(self, config, save_callback)
    Screen._ctor(self, "DSTAIConfigScreen")
    config = config or {}
    self.save_callback = save_callback

    self.root = self:AddChild(TEMPLATES.ScreenRoot())
    self.tint = self.root:AddChild(TEMPLATES.BackgroundTint())

    local buttons = {
        {
            text = "保存",
            cb = function()
                local base_url = self.base_url.textbox:GetString() or ""
                local model = self.model.textbox:GetString() or ""
                local api_key = self.api_key.textbox:GetString() or ""
                self.save_callback(base_url, model, api_key)
                TheFrontEnd:PopScreen(self)
            end,
        },
        {
            text = "取消",
            cb = function() TheFrontEnd:PopScreen(self) end,
        },
    }

    self.dialog = self.root:AddChild(TEMPLATES.CurlyWindow(720, 390, "DST AI Assistant 配置", buttons))
    self.form = self.dialog:AddChild(Widget("form"))
    self.form:SetPosition(0, 45)

    self.base_url = self.form:AddChild(TEMPLATES.LabelTextbox("Base URL", config.base_url or "", 140, 470, 46, 8, NEWFONT, 24, -20))
    self.base_url:SetPosition(0, 80)
    self.base_url.textbox:SetTextLengthLimit(500)

    self.model = self.form:AddChild(TEMPLATES.LabelTextbox("Model", config.model or "", 140, 470, 46, 8, NEWFONT, 24, -20))
    self.model:SetPosition(0, 20)
    self.model.textbox:SetTextLengthLimit(200)

    local key_hint = config.has_api_key and "（已配置；留空表示保留原密钥）" or "（尚未配置）"
    self.api_key = self.form:AddChild(TEMPLATES.LabelTextbox("API Key", "", 140, 470, 46, 8, NEWFONT, 24, -20))
    self.api_key:SetPosition(0, -40)
    self.api_key.textbox:SetTextLengthLimit(500)
    self.api_key.textbox:SetPassword(true)

    self.hint = self.form:AddChild(Text(NEWFONT, 20, key_hint))
    self.hint:SetPosition(40, -88)
    self.hint:SetColour(0.75, 0.75, 0.75, 1)

    self.base_url.textbox:SetOnTabGoToTextEditWidget(function() return self.model.textbox end)
    self.model.textbox:SetOnTabGoToTextEditWidget(function() return self.api_key.textbox end)
    self.api_key.textbox:SetOnTabGoToTextEditWidget(function() return self.base_url.textbox end)
    self.default_focus = self.base_url.textbox
end)

function AIConfigScreen:OnControl(control, down)
    if AIConfigScreen._base.OnControl(self, control, down) then
        return true
    end
    if not down and control == CONTROL_CANCEL then
        TheFrontEnd:PopScreen(self)
        return true
    end
end

return AIConfigScreen
