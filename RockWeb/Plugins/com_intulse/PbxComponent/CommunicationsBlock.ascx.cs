using System;
using System.ComponentModel;
using System.Linq;
using System.Web.UI;
using com.intulse.PbxComponent.Services;
using Rock;
using Rock.Data;
using Rock.Model;
using Rock.Web.UI.Controls;
using Rock.Web.UI;
using System.Web.UI.WebControls;
using com.intulse.PbxComponent.Models;
using System.Collections.Generic;
using Rock.Web.Cache;
using System.Text.RegularExpressions;

namespace RockWeb.Plugins.com_intulse.PbxComponent
{
    /// <summary>
    /// Intulse Communications Block
    /// </summary>
    [DisplayName("Intulse Communication Block")]
    [Category("Intulse > Communication Block")]
    [Description("Displays all Intulse communications")]
    public partial class CommunicationsBlock : RockBlock
    {
        private CallDetailRecordService _cdrService = new CallDetailRecordService(new RockContext());
        private SmsMessageService _smsService = new SmsMessageService(new RockContext());
        private CommunicationNoteService _noteService = new CommunicationNoteService(new RockContext());
        private SettingService _settingService = new SettingService(new RockContext());

        protected static class PageParameterKey
        {
            public const string personIdKey = "PersonId";
            public const string businessIdKey = "BusinessId";
        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {


            base.OnInit(e);

            // Default date range
            filterDates.LowerValue = DateTime.Today.AddMonths(-3);
            filterDates.UpperValue = DateTime.Today.AddDays(1);

            gridFilterCommunications.Show();
            gridCommunications.GridRebind += gridCommunications_GridRebind;
            gridCommunications.Columns[5].Visible = bool.Parse(this._settingService.GetSetting(com.intulse.PbxComponent.Migrations.IntulseAttributes.IntulseSettings.ShowRecordings_Name)); ;

            this.BlockUpdated += Block_BlockUpdated;
            this.AddConfigurationUpdateTrigger(upnlContent);
        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);

            if (!Page.IsPostBack)
            {
                BindGrid();
            }
        }

        /// <summary>
        /// Creates the Message/Notes column
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="GridViewRowEventArgs"/> instance containing the event data.</param>
        protected void gridCommunications_RowDataBound(object sender, GridViewRowEventArgs e)
        {
            var communication = e.Row.DataItem as CommunicationDisplay;

            if (communication == null)
            {
                return;
            }

            var communicationNoteLiteral = e.Row.FindControl("communicationNoteLiteral") as Literal;

            if (communicationNoteLiteral != null)
            {
                var iconMarkup = string.Empty;
                var attachmentMarkup = string.Empty;

                if (communication.Type == "Call")
                {
                    iconMarkup = communication.WasAnswered ? @"<i class=""fa fa-phone fa-flip-horizontal mr-2 badge"" data-toggle=""tooltip"" data-original-title=""Call was answered"" style=""display: inline-block!important; background-color: #28a745; min-width: 31.5px""></i>"
                                                            : @"<i class=""fa fa-phone-slash fa-flip-horizontal mr-2 badge"" data-toggle=""tooltip"" data-original-title=""Call was not answered"" style=""display: inline-block!important; background-color: #dc3545""></i>";
                }
                else
                {
                    var imageFilesMarkup = string.Empty;
                    var otherFilesMarkup = string.Empty;

                    communication.Attachments.ForEach(a =>
                    {
                        if (a.MimeType.StartsWith("image"))
                        {
                            imageFilesMarkup += $@"<a href=""{a.Url}"" target=""_blank"" class=""mr-2""><img src=""{a.Url}"" style=""max-width:100px; max-height:100px;""></a>";
                        }
                        else
                        {
                            otherFilesMarkup += $@"<div><a href=""{a.Url}"" target=""_blank"">{a.Name}</a></div>";
                        }
                    });

                    if (!string.IsNullOrWhiteSpace(imageFilesMarkup) && !string.IsNullOrWhiteSpace(otherFilesMarkup))
                    {
                        imageFilesMarkup = $@"<div class=""mb-2"">{imageFilesMarkup}</div>";
                    }
                    else
                    {
                        imageFilesMarkup = $@"<div>{imageFilesMarkup}</div>";
                    }

                    attachmentMarkup = imageFilesMarkup + otherFilesMarkup;
                }

                if (!string.IsNullOrWhiteSpace(attachmentMarkup))
                {
                    attachmentMarkup = $@"<div class=""mt-2"">{attachmentMarkup}</div>";
                }

                communicationNoteLiteral.Text = iconMarkup + communication.Description + attachmentMarkup;

                var noteMarkup = string.Empty;

                if (!string.IsNullOrWhiteSpace(communication.Note))
                {
                    noteMarkup = $@"<div style=""margin-top:5px; padding-top:5px; border-top:1px solid #ccc; font-size:80%;""><strong>NOTE: </strong>{communication.Note}</div>";
                }

                communicationNoteLiteral.Text += $@"<!--intulse-note-start-->{noteMarkup}<!--intulse-note-end-->";
            }

            // TODO: Check if "visible" recordings is just display none? Needs to not be in DOM
            var showRecordingsButton = e.Row.FindControl("showRecordingsButton") as BootstrapButton;

            if (communication.WasAnswered && communication.Recordings != null)
            {
                showRecordingsButton.CommandArgument = string.Join(",", communication.Recordings);
            }
            else
            {
                showRecordingsButton.Visible = false;
            }

            var sourceRepeater = e.Row.FindControl("sourceRepeater") as Repeater;
            var sources = communication.SourceNames.Any() ? communication.SourceNames.Select(name => $"{name} ({communication.SourceNumber})").ToList() : new List<string> { communication.SourceNumber };
            sourceRepeater.DataSource = sources;
            sourceRepeater.DataBind();

            var destinationRepeater = e.Row.FindControl("destinationRepeater") as Repeater;
            var destinations = communication.DestinationNames.Any() ? communication.DestinationNames.Select(name => $"{name} ({communication.DestinationNumber})").ToList() : new List<string> { communication.DestinationNumber };
            destinationRepeater.DataSource = destinations;
            destinationRepeater.DataBind();
        }

        /// <summary>
        /// Loads the Recordings for a row
        /// </summary>
        /// <param name="sender">The source of the event - a button.</param>
        /// <param name="e">A comma delimited string containing the recording keys to load.</param>
        protected void loadRecordings(object sender, CommandEventArgs e)
        {
            var button = (BootstrapButton)sender;
            var row = (GridViewRow)button.NamingContainer;

            button.Visible = false;

            var recordingKeys = e.CommandArgument.ToString().Split(',').ToList();

            var audioMarkup = string.Empty;

            recordingKeys.ForEach(k =>
            {
                audioMarkup += $@"<div><audio src=""/api/com.intulse/cdr/recording/{k}"" controls></audio></div>";
            });

            var recordingsLiteral = row.FindControl("recordingsLiteral") as Literal;

            recordingsLiteral.Text = audioMarkup;
        }

        /// <summary>
        /// Handles the GridRebind event of the gridCommunications control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        private void gridCommunications_GridRebind(object sender, EventArgs e)
        {
            BindGrid();
        }

        /// <summary>
        /// Handles the BlockUpdated event of the control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void Block_BlockUpdated(object sender, EventArgs e)
        {
            BindGrid();
        }

        /// <summary>
        /// Handles applying filters.
        /// </summary>
        protected void gridFilterCommunications_ApplyFilterClick(object sender, EventArgs e)
        {
            BindGrid();
        }

        /// <summary>
        /// Handles the button click to open the note modal
        /// </summary>
        protected void gridCommunications_Edit(object sender, RowEventArgs e)
        {
            noteModalCommunicationId.Value = e.RowKeyValue.ToString();

            var note = _noteService.GetNoteByCommunicationId(noteModalCommunicationId.Value);

            noteModalTextbox.Text = note;
            noteModal.OnOkScript = e.RowIndex.ToString();
            noteModal.Show();
        }

        /// <summary>
        /// Handles saving a note
        /// </summary>
        protected void noteModal_Save(object sender, EventArgs e)
        {
            noteModal.Hide();

            _noteService.CreateOrUpdateCommunicationNote(noteModalCommunicationId.Value, noteModalTextbox.Text);

            var rowIndex = noteModal.OnOkScript;

            var row = gridCommunications.Rows[int.Parse(rowIndex)];
            var communicationNoteLiteral = row.FindControl("communicationNoteLiteral") as Literal;

            if (communicationNoteLiteral != null)
            {
                var noteMarkup = string.Empty;

                if (!string.IsNullOrWhiteSpace(noteModalTextbox.Text))
                {
                    noteMarkup = $@"<div style=""margin-top:5px; padding-top:5px; border-top:1px solid #ccc; font-size:80%;""><strong>NOTE: </strong>{noteModalTextbox.Text}</div>";
                }

                communicationNoteLiteral.Text = Regex.Replace(communicationNoteLiteral.Text, "<!--intulse-note-start-->.*<!--intulse-note-end-->", $"<!--intulse-note-start-->{noteMarkup}<!--intulse-note-end-->");
            }
        }

        /// <summary>
        /// Binds the data to the grid
        /// </summary>
        protected void BindGrid()
        {
            errorBox.Visible = false;

            var communications = new List<CommunicationDisplay>();
            int personId;

            if (!int.TryParse(PageParameter(PageParameterKey.personIdKey), out personId))
            {
                personId = int.Parse(PageParameter(PageParameterKey.businessIdKey));
            }

            var showCdr = filterShowCdr.Checked;
            var showSms = filterShowSms.Checked;
            var nameFilter = filterName.Text;
            var numberFilter = filterNumber.Text;
            var dateFilter = filterDates.DelimitedValues;

            var picker = new DateRangePicker();
            picker.DelimitedValues = dateFilter;

            var filterStartDate = picker.LowerValue;
            var filterEndDate = picker.UpperValue;

            if (filterStartDate != null)
            {
                filterStartDate = ((DateTime)filterStartDate).ToUniversalTime();
            }

            if (filterEndDate != null)
            {
                filterEndDate = ((DateTime)filterEndDate).ToUniversalTime().AddDays(1); // Have to add one day to end date as it defaults to midnight (making it excluded)
            }

            try
            {
                if (showCdr)
                {
                    communications.AddRange(_cdrService.GetPersonsCdrs(personId, nameFilter, numberFilter, filterStartDate, filterEndDate));
                }

                if (showSms)
                {
                    communications.AddRange(_smsService.GetPersonSmsMessages(personId, nameFilter, numberFilter, filterStartDate, filterEndDate));
                }

                if (communications.Count > 0)
                {
                    SortProperty sortProperty = gridCommunications.SortProperty;

                    if (sortProperty != null)
                    {
                        var property = communications
                            .First()
                            .GetType()
                            .GetProperty(sortProperty.Property);

                        if (sortProperty.Direction == SortDirection.Ascending)
                        {
                            communications = communications.OrderBy(r => property.GetValue(r, null)).ToList();
                        }
                        else
                        {
                            communications = communications.OrderByDescending(r => property.GetValue(r, null)).ToList();
                        }
                    }
                    else
                    {
                        communications = communications.OrderByDescending(r => r.CommunicationDateUtc).ToList();
                    }

                    communications.ForEach(r => r.CommunicationDateUtc = RockDateTime.ConvertLocalDateTimeToRockDateTime(r.CommunicationDateUtc.ToLocalTime()));
                }

                gridCommunications.DataSource = communications;
            }
            catch (Exception ex)
            {
                LogException(ex);
                errorBox.Visible = true;
            }

            errorBox.DataBind();
            gridCommunications.DataBind();
        }
    }
}