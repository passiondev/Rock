<%@ Control Language="C#" AutoEventWireup="true" CodeFile="ApplePayConfiguration.ascx.cs" Inherits="RockWeb.Plugins.org_mywell.Gateway.ApplePayConfiguration" %>

<asp:UpdatePanel ID="upnlContent" runat="server">
    <ContentTemplate>

        <asp:Panel ID="pnlView" runat="server" CssClass="panel panel-block">

            <div class="panel-heading">
                <h1 class="panel-title">
                    <i class="fa fa-exchange-alt"></i>
                    My Well Apple Pay Configuration
                </h1>

            </div>
            <div class="panel-body">
                <div style="margin: 0 auto; width: 690px; max-width: 100%;">
                    <div class="text-center">
                        <asp:Image ID="imgMyWellLogo" CssClass="width-half margin-b-lg" runat="server" />
                         <asp:Literal runat="server" ID="lDescription" />
                    </div>
                     <!--Errors that happen during activation of schedules -->
                    <asp:Panel ID="pnErrorMessage" Visible="false" runat="server">
                        <div class="mt-4 alert alert-danger rounded-lg shadow-lg">
                                <asp:Label ID="lErrorMessageTitle" runat="server"></asp:Label>
                            <p class="pt-3">
                                <asp:Label ID="lErrorBody" runat="server" />
                            </p>
                        </div>
                    </asp:Panel>
                    <div class="alert alert-info text-center margin-v-lg">
                        <b>Domain Name</b>
                        <p class="margin-b-md">
                            <asp:Literal ID="lExternalRockAddress" runat="server" />
                        </p>
                          <asp:Panel ID="pnlApplePayId" runat="server">
                        <b>Apple Pay Merchant Id</b>
                        <p>
                            <asp:Literal runat="server" ID="lMyWellApplePayId" />
                        </p>
                        <b>Benevity Id</b>
                        <p>
                            <asp:Literal runat="server" ID="lBenevityId" />
                        </p>
                        </asp:Panel>
                    </div>

                    <asp:Panel ID="pnlVerifyMode" runat="server">
                        <Rock:RockTextBox ID="tbBenevityId" runat="server" Label="Benevity ID" Required="true" />
                        <div class="text-center margin-t-xl">
                            <asp:LinkButton ID="btnVerifyDomain" runat="server" CssClass="btn btn-primary" Text="Verify Domain" OnClick="btnVerifyDomain_Click" />
                        </div>
                    </asp:Panel>
                    <div class="text-center margin-t-lg margin-b-lg">
                        <a href="https://www.mywell.org">https://www.mywell.org</a>
                    </div>
                </div>
            </div>
        </div>
        </asp:Panel>

    </ContentTemplate>
</asp:UpdatePanel>
