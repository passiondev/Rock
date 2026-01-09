using System;
using System.ComponentModel;
using com.intulse.PbxComponent.Services;
using Rock;
using Rock.Data;
using Rock.Model;
using Rock.Web.UI.Controls;
using Rock.Web.UI;
using System.Web.UI.WebControls;
using System.Collections.Generic;
using com.intulse.PbxComponent.Entities;
using com.intulse.PbxComponent.Migrations.IntulseAttributes;
using Rock.Web.Cache;
using com.intulse.PbxComponent.Rest.Controllers.DTOs;
using System.Net;
using System.Linq;

namespace RockWeb.Plugins.com_intulse.PbxComponent
{
    /// <summary>
    /// Intulse Communications Block
    /// </summary>
    [DisplayName("Intulse Settings Block")]
    [Category("Intulse > Settings ")]
    [Description("Handles settings for the Intulse plugin")]
    public partial class IntulseSettingsBlock : RockBlock
    {
        private SettingService _settingService = new SettingService(new RockContext());

        public List<Panel> panels = new List<Panel>();

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);

            var settings = _settingService.GetSettings();
            var sections = new Dictionary<string, List<SettingEntity>>();

            settings.ForEach(setting =>
            {
                if (setting.Category != IntulseSettings.CategoryHidden)
                {
                    if (!sections.ContainsKey(setting.Category))
                    {
                        sections.Add(setting.Category, new List<SettingEntity> { setting });
                    }
                    else
                    {
                        sections[setting.Category].Add(setting);
                    }
                }
            });

            Panel currentPanel = null;

            foreach (KeyValuePair<string, List<SettingEntity>> entry in sections)
            {
                currentPanel = new Panel();
                currentPanel.Controls.Add(new Label { Text = entry.Key, CssClass = "h3" });
                panels.Add(currentPanel);

                entry.Value.ForEach(setting =>
                {
                    switch (setting.DataType)
                    {
                        case "int":
                            currentPanel.Controls.Add(new NumberBox
                            {
                                ID = "control_" + setting.Setting.Replace(" ", ""),
                                Label = setting.Setting,
                                IntegerValue = int.Parse(setting.Value),
                                NumberType = ValidationDataType.Integer,
                                MinimumValue = "0",
                                Required = true,
                                AutoPostBack = true,
                                ToolTip = setting.Description
                            });

                            break;
                        case "boolean":
                            currentPanel.Controls.Add(new RockDropDownList
                            {
                                ID = "control_" + setting.Setting.Replace(" ", ""),
                                Label = setting.Setting,
                                Required = true,
                                AutoPostBack = true,
                                Items = { "True", "False"},
                                SelectedValue = setting.Value,
                                ToolTip = setting.Description
                            });

                            break;
                        case "string":
                        default:
                            currentPanel.Controls.Add(new RockTextBox
                            {
                                ID = "control_" + setting.Setting.Replace(" ", ""),
                                Label = setting.Setting,
                                Text = setting.Value,
                                Required = true,
                                AutoPostBack = true,
                                ToolTip = setting.Description
                            });

                            break;
                    }
                });
            }

            panels.ForEach(panel =>
            {
                controlPanel.Controls.Add(panel);
            });

            var webhookSetting = settings.FirstOrDefault(s => s.Setting == IntulseSettings.WebhookCreated_Name);

            if (webhookSetting != null && bool.Parse(webhookSetting.Value) == true)
            {
                webhookPanel.Visible = false;
            }
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);

            buttonMessage.AddCssClass("hide");
            saveButton.Enabled = false;

            validatePanels();
        }

        protected void saveButton_Click(object sender, EventArgs e)
        {
            if (validatePanels())
            {
                saveButton.Enabled = false;
                buttonMessage.Visible = false;

                panels.ForEach(panel =>
                {
                    foreach (var control in panel.Controls)
                    {
                        if (control is NumberBox)
                        {
                            var numberbox = (NumberBox)control;
                            _settingService.UpdateSetting(numberbox.Label, numberbox.Text);
                        }
                        else if (control is RockTextBox)
                        {
                            var textbox = (RockTextBox)control;
                            _settingService.UpdateSetting(textbox.Label, textbox.Text);
                        }
                        else if (control is RockDropDownList)
                        {
                            var dropdown = (RockDropDownList)control;
                            _settingService.UpdateSetting(dropdown.Label, dropdown.SelectedValue);
                        }
                    }
                });

                buttonMessage.Visible = true;
                saveButton.Enabled = true;
            }
        }

        protected void webhookButton_Click(object sender, EventArgs e)
        {
            var apiKey = string.Empty;

            panels.ForEach(panel =>
            {
                if (string.IsNullOrWhiteSpace(apiKey))
                {
                    foreach (var control in panel.Controls)
                    {
                        if (control is RockTextBox)
                        {
                            var textbox = (RockTextBox)control;

                            if (textbox.Label == IntulseSettings.ApiKey_Name)
                            {
                                apiKey = textbox.Text;
                                break;
                            }
                        }
                    }
                }
            });

            webhookButtonMessage.Visible = false;

            if (!string.IsNullOrWhiteSpace(apiKey))
            {
                try
                {
                    var webhookUrl = GlobalAttributesCache.Get().GetValue("InternalApplicationRoot") + "Webhooks/Intulse.ashx";
                    var settingsService = new SettingService(new RockContext());

                    var parameters = new WebhookRequest
                    {
                        Url = webhookUrl,
                        Type = "TextMessageReceived"
                    };
                    var jsonParameters = Newtonsoft.Json.JsonConvert.SerializeObject(parameters);

                    using (var client = new WebClient())
                    {
                        client.Headers.Set(HttpRequestHeader.ContentType, "application/json");
                        client.Headers.Add("X-API-Key: " + apiKey);

                        var apiResponse = client.UploadString("https://api.intulse.com/webhooks", jsonParameters);
                        var response = Newtonsoft.Json.JsonConvert.DeserializeObject<WebhookRequestResponse>(apiResponse);
                    }

                    webhookButtonMessage.Text = "Webhook created!";
                    webhookButtonMessage.Visible = true;
                    webhookButton.Enabled = false;

                    settingsService.UpdateSetting(IntulseSettings.WebhookCreated_Name, "True");
                }
                catch (Exception)
                {
                    webhookButtonMessage.Text = "Error while trying to create webhook! Make sure your that you have entered your Intulse API Key above and that your Internal Application Root Global Setting is filled in.";
                    webhookButtonMessage.Visible = true;
                }
            }
            else
            {
                webhookButtonMessage.Text = "Please enter your Intulse API Key above.";
                webhookButtonMessage.Visible = true;
            }
        }

        private bool validatePanels()
        {
            var isValid = true;

            panels.ForEach(panel =>
            {
                foreach (var control in panel.Controls)
                {
                    if (control is NumberBox) // NumberBox needs to be checked first as it inherits from NumberBoxBase which inherits from RockTextBox
                    {
                        var numberbox = (NumberBox)control;
                        int intValue;

                        if (!int.TryParse(numberbox.Text, out intValue) || intValue < 0)
                        {
                            isValid = false;
                            numberbox.AddCssClass("invalid-control");
                        }
                        else
                        {
                            numberbox.RemoveCssClass("invalid-control");
                        }
                    }
                    else if (control is RockTextBox)
                    {
                        var textbox = (RockTextBox)control;

                        if (string.IsNullOrWhiteSpace(textbox.Text))
                        {
                            isValid = false;
                            textbox.AddCssClass("invalid-control");
                        }
                        else
                        {
                            textbox.RemoveCssClass("invalid-control");
                        }
                    }
                }

                saveButton.Enabled = isValid ? true : false;
                webhookButton.Enabled = isValid ? true : false;
            });

            return isValid;
        }
    }
}