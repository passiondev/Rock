<%@ Control Language="C#" AutoEventWireup="true" CodeFile="Demo.ascx.cs" Inherits="RockWeb.Plugins.org_passion.Demo" %>

<asp:UpdatePanel ID="upnlContent" runat="server">

    <ContentTemplate>
                    <div class="panel-heading">
                <h1 class="panel-title">
                    <i class="fa fa-star"></i> 
                    Blank Detail Block
                </h1>

                <div class="panel-labels">
                    <Rock:HighlightLabel ID="hlblTest" runat="server" LabelType="Info" Text="Label" />
                </div>
            </div>
        <Rock:Grid ID="gPeople" runat="server" AllowSorting="true">
            <Columns>
                <asp:BoundField DataField="FirstName" HeaderText="First Name" />
                <asp:BoundField DataField="LastName" HeaderText="Last Name" />
            </Columns>
        </Rock:Grid>

    </ContentTemplate>
</asp:UpdatePanel>