<%@ Control Language="C#" AutoEventWireup="true" CodeFile="IntulseSettingsBlock.ascx.cs" Inherits="RockWeb.Plugins.com_intulse.PbxComponent.IntulseSettingsBlock" %>
<style>
    .rock-text-box, .rock-drop-down-list, .number-box {
        margin-top: 10px;
        margin-bottom: 25px;
    }

    .invalid-control {
        border-color: red;
    }

    .hide {
        display: none;
    }
</style>

<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>
        <asp:Panel ID="pnlWrapper" runat="server" CssClass="panel panel-block">
            <div class="panel-heading clearfix">
                <h3 class="panel-title pull-left"><i class="fa fa-phone"></i> Intulse Settings</h3>
            </div>

            <div class="panel-body">
                <asp:Panel ID="controlPanel" runat="server" Visible="true" Width="30%">
                </asp:Panel>

                <asp:Panel ID="webhookPanel" runat="server" Visible="true">
                    <asp:LinkButton ID="webhookButton" runat="server" CssClass="btn btn-primary" Enabled="true" OnClick="webhookButton_Click">Create Webhook</asp:LinkButton>
                    <asp:Label ID="webhookButtonMessage" runat="server" Visible="false">Webhook created!</asp:Label>
                </asp:Panel>
                <br />

                <asp:Panel ID="savePanel" runat="server" Visible="true">
                    <asp:LinkButton ID="saveButton" runat="server" CssClass="btn btn-primary" Enabled="true" OnClick="saveButton_Click">Save</asp:LinkButton>
                    <asp:Label ID="buttonMessage" runat="server" Visible="false">Settings saved!</asp:Label>
                </asp:Panel>
            </div>
        </asp:Panel>
    </ContentTemplate>
</asp:UpdatePanel>