// <copyright>
// Copyright by the Spark Development Network
//
// Licensed under the Rock Community License (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.rockrms.com/license
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// </copyright>

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data.Entity;
using System.Linq;
using System.Web.UI;
using System.Web.UI.WebControls;
using Rock;
using Rock.Attribute;
using Rock.Data;
using Rock.Model;
using Rock.Web.Cache;
using Rock.Web.UI;
using Rock.Web.UI.Controls;
using Rock.Security;
using Newtonsoft.Json;
using Rock.Communication;
using Rock.Cms.StructuredContent;

namespace RockWeb.Blocks.RSVP
{
    /// <summary>
    /// Displays the details of the given RSVP occurrence.
    /// </summary>
    [DisplayName("Passion RSVP BETA")]
    [Category("RSVP")]
    [Description("This is the test block!")]

    #region Block Attributes

    [BooleanField("Display Form When Signed In",
        Key = AttributeKey.DisplayFormWhenSignedIn,
        Description = "If signed in and Display Form When Signed In is disabled, only the accept and decline buttons are shown.",
        DefaultBooleanValue = true,
        Order = 0)]

    [TextField("Accept Button Label",
        Key = AttributeKey.AcceptButtonLabel,
        Description = "The label for the Accept button.",
        DefaultValue = "Accept",
        Order = 2)]

    [TextField("Decline Button Label",
        Key = AttributeKey.DeclineButtonLabel,
        Description = "The label for the Decline button.",
        DefaultValue = "Decline",
        Order = 3)]

    [MemoField("Default Accept Message",
        Key = AttributeKey.DefaultAcceptMessage,
        Description = "The default message displayed when an RSVP is accepted.",
        DefaultValue = "We have received your response. Thanks, and we’ll see you soon!",
        Order = 4,
        AllowHtml = true)]

    [MemoField("Default Decline Message",
        Key = AttributeKey.DefaultDeclineMessage,
        Description = "The default message displayed when an RSVP is declined.",
        DefaultValue = "Sorry to hear you won’t make it, but hopefully we’ll see you again soon!",
        Order = 5)]

    [DefinedValueField("Default Decline Reasons",
        Key = AttributeKey.DefaultDeclineReasons,
        Description = "Default Decline Reasons to be displayed.  Setting decline reasons on the Attendance Occurrence will override these.",
        DefaultValue = "",
        Order = 6)]

    [TextField("Multigroup Mode RSVP Title",
        Key = AttributeKey.MultigroupModeRSVPTitle,
        Description = "The page title when a user is RSVPing for multiple groups.",
        DefaultValue = "",
        IsRequired = false,
        Order = 8)]

    [MemoField("Multigroup Accept Message",
        Key = AttributeKey.MultigroupAcceptMessage,
        Description = "The message displayed when one or more RSVPs are accepted in Multigroup mode.  Will include a list of accepted events with the key \"AcceptedRsvps\".",
        DefaultValue = "Thanks for letting us know!",
        Order = 9,
        AllowHtml = true)]

    [DefinedValueField(
        "Connection Status",
        Key = AttributeKey.ConnectionStatus,
        Description = "The connection status to use for new individuals (default = 'Web Prospect'.)",
        DefinedTypeGuid = "2E6540EA-63F0-40FE-BE50-F2A84735E600",
        IsRequired = true,
        AllowMultiple = false,
        DefaultValue = "368DD475-242C-49C4-A42C-7278BE690CC2",
        Order = 11)]

    [DefinedValueField(
        "Record Status",
        Key = AttributeKey.RecordStatus,
        Description = "The record status to use for new individuals (default = 'Pending'.)",
        DefinedTypeGuid = "8522BADD-2871-45A5-81DD-C76DA07E2E7E",
        IsRequired = true,
        AllowMultiple = false,
        DefaultValue = "283999EC-7346-42E3-B807-BCE9B2BABB49",
        Order = 12)]


    #endregion

    public partial class RSVPResponse : RockBlock
    {
        private static class AttributeKey
        {
            public const string DisplayFormWhenSignedIn = "DisplayFormWhenSignedIn";
            public const string AcceptButtonLabel = "AcceptButtonLabel";
            public const string DeclineButtonLabel = "DeclineButtonLabel";
            public const string DefaultAcceptMessage = "DefaultAcceptMessage";
            public const string DefaultDeclineMessage = "DefaultDeclineMessage";
            public const string DefaultDeclineReasons = "DefaultDeclineReasons";
            public const string MultigroupModeRSVPTitle = "MultigroupModeRSVPTitle";
            public const string MultigroupAcceptMessage = "MultigroupAcceptMessage";
            public const string ConnectionStatus = "ConnectionStatus";
            public const string RecordStatus = "RecordStatus";
        }

        private static class PageParameterKey
        {
            public const string AttendanceOccurrenceId = "AttendanceOccurrenceId";
            public const string AttendanceOccurrenceIds = "AttendanceOccurrenceIds";
            public const string PersonActionIdentifier = "p";
            public const string IsAccept = "IsAccept";
            public const string AcceptButtonText = "AcceptButtonText";
            public const string AcceptButtonColor = "AcceptButtonColor";
            public const string AcceptButtonFontColor = "AcceptButtonFontColor";
            public const string DeclineButtonText = "DeclineButtonText";
            public const string DeclineButtonColor = "DeclineButtonColor";
            public const string DeclineButtonFontColor = "DeclineButtonFontColor";
            public const string IncludeDecline = "IncludeDecline";

        }

        #region Properties

        /// <summary>
        /// Stores data collection for multiple occurrence responses.
        /// </summary>
        private List<OccurrenceDataItem> MultipleOccurrenceDataItems { get; set; }

        #endregion

        #region Control Methods

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);

            string script = @"
$('input.rsvp-list-input').each(function () {
    var $cbx = $(this)[0];

    if ($cbx.checked) {
        var $header = $(this).closest('header');
        $header.siblings('.panel-body').show();
    }
});

$('input.rsvp-list-input').on('click', function (e) {
    var $cbx = $(this)[0];
    var $header = $(this).closest('header');

    if ($cbx.checked) {
        $header.siblings('.panel-body').slideDown();
        $header.siblings('.panel-body').find('span[id$=rfv]').each(function () {
            document.getElementById($(this).attr('id')).enabled = true;
        });
    } else {
        $header.siblings('.panel-body').slideUp();
        $header.siblings('.panel-body').find('span[id$=rfv]').each(function () {
            document.getElementById($(this).attr('id')).enabled = false;
        });
    }
});

$(document).ready(function () {

    $('.js-rsvp-item').find('span[id$=rfv]').each(function () {
        document.getElementById($(this).attr('id')).enabled = false;
    });

});

";
            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "DefinedValueChecklistScript", script, true);

            RegisterDietaryOtherRevealScript();

            lbAccept_Multiple.Text = GetAttributeValue(AttributeKey.AcceptButtonLabel);
            lbAccept_Single.Text = GetAttributeValue(AttributeKey.AcceptButtonLabel);
            lbDecline_Single.Text = GetAttributeValue(AttributeKey.DeclineButtonLabel);


            // Moving this method down to pass in attendanceId parameter/argument
            int? occurrenceId = PageParameter(PageParameterKey.AttendanceOccurrenceId).AsIntegerOrNull();
            SetButtonProperties(occurrenceId ?? 0);

            var person = GetPerson();
            if (person == null)
            {
                // Invalid person action identifier and/or user is not logged in.
                nbNotAuthorized.Visible = true;
                return;
            }

            if (!Page.IsPostBack)
            {
                bool isAccept = (PageParameter(PageParameterKey.IsAccept) == "1");
                bool isDecline = (PageParameter(PageParameterKey.IsAccept) == "0");
                var attendanceOccurrenceId = PageParameter(PageParameterKey.AttendanceOccurrenceId).AsIntegerOrNull();
                var attendanceOccurrenceIdList = GetMultipleOccurrenceIds();
                


                if ((attendanceOccurrenceId == null) && (attendanceOccurrenceIdList.Count == 1))
                {
                    // If only one occurrence ID is specified in the list, move it to the individual occurrence ID and treat it as a single RSVP response.
                    attendanceOccurrenceId = attendanceOccurrenceIdList.First();
                }

                if (attendanceOccurrenceId != null)
                {
                    // Using a single occurrece.
                    if (isAccept)
                    {
                        if (!HasPersonActionIdentifier() && CurrentPerson == null)
                        {
                            ShowSingleOccurrence_Choice(attendanceOccurrenceId.Value, person);
                        }
                        else if (GroupHasAttributes())
                        {
                            ShowSingleOccurrence_Choice(attendanceOccurrenceId.Value, person);
                        }
                        else
                        {
                            WriteEmailAcceptResponse(attendanceOccurrenceId.Value, person);
                            ShowSingleOccurrence_Accept(attendanceOccurrenceId.Value, person);
                            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
                        }
                    }
                    else if (isDecline)
                    {
                        ShowSingleOccurrence_Decline(attendanceOccurrenceId.Value, person);
                        ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
                    }
                    else
                    {
                        ShowSingleOccurrence_Choice(attendanceOccurrenceId.Value, person);
                    }
                }
                else
                {
                    if (attendanceOccurrenceIdList.Any())
                    {
                        ShowMultipleOccurrence_Choice(attendanceOccurrenceIdList, person);
                    }
                    else
                    {
                        // No occurrence IDs were supplied.
                        Show404();
                    }
                }

            }
            else
            {
                if (HasPersonActionIdentifier())
                {
                    PopulatePersonIdentityFields(person, true);
                }

                var attendanceOccurrenceId = PageParameter(PageParameterKey.AttendanceOccurrenceId).AsIntegerOrNull();
                if (attendanceOccurrenceId != null)
                {
                    ConfigurePhoneFieldForOccurrence(attendanceOccurrenceId.Value, person);
                    BuildAttributeControls();
                }
                var attendanceOccurrenceIdList = GetMultipleOccurrenceIds();
                if (attendanceOccurrenceIdList.Any())
                {
                    ConfigurePhoneFieldForOccurrences(attendanceOccurrenceIdList, person);
                    RebuildMultipleOccurrenceDataItems(attendanceOccurrenceIdList, person);
                }
            }
        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad(EventArgs e)
        {

        }

        /// <summary>
        /// Saves any user control view-state changes that have occurred since the last page postback.
        /// </summary>
        /// <returns>
        /// Returns the user control's current view state. If there is no view state associated with the control, it returns null.
        /// </returns>
        protected override object SaveViewState()
        {
            var jsonSetting = new JsonSerializerSettings
            {
                ReferenceLoopHandling = ReferenceLoopHandling.Ignore,
                ContractResolver = new Rock.Utility.IgnoreUrlEncodedKeyContractResolver()
            };
            ViewState["MultipleOccurrenceDataItems"] = JsonConvert.SerializeObject(MultipleOccurrenceDataItems, Formatting.None, jsonSetting);
            return base.SaveViewState();
        }

        #endregion

        #region Events

        protected void lbAccept_Single_Click(object sender, EventArgs e)
        {
            valGuests.Visible = false;
            valGuests.Text = string.Empty;
            valDecline.Visible = false;
            valDecline.Text = string.Empty;

            var attendanceOccurrenceId = PageParameter(PageParameterKey.AttendanceOccurrenceId).AsIntegerOrNull();

            if (!HasPersonActionIdentifier() && CurrentPerson == null && !HasRequiredPersonIdentityFields())
            {
                valDecline.Text = "You must provide your name/email before accepting.";
                valDecline.Visible = true;
                return;
            }

            var person = GetPerson();
            if (person == null || attendanceOccurrenceId == null)
            {
                // Invalid person action identifier.
                nbNotAuthorized.Visible = true;
                return;
            }

            //if ( string.IsNullOrWhiteSpace( PageParameter( PageParameterKey.PersonActionIdentifier ) ) )
            //{
            //    UpdatePersonRecord(person);
            //}

            if (dpBirthDate1.Visible && dpBirthDate1.Required && !dpBirthDate1.SelectedDate.HasValue && !string.IsNullOrEmpty(dpBirthDate1.Text))
            {
                valGuests.Text = "Please enter a valid birth date in MM/DD/YYYY format.";
                valGuests.Visible = true;
                return;
            }

            if (acAddress.Visible && acAddress.Required)
            {
                if (string.IsNullOrWhiteSpace(acAddress.Street1) || string.IsNullOrWhiteSpace(acAddress.City) ||
                    string.IsNullOrWhiteSpace(acAddress.State) || string.IsNullOrWhiteSpace(acAddress.PostalCode))
                {
                    valDecline.Text = "Please enter a complete address including street, city, state, and zip code.";
                    valDecline.Visible = true;
                    return;
                }
            }

            // Dietary Restrictions (PTP-18203): the free-text is required once "Other" is selected, and
            // this is the only place that is enforced. rtbDietaryOther is deliberately not declared
            // Required -- see the note in the .ascx -- so this check replaces the validator entirely.
            // Same pattern as the birth date and address checks above.
            if (pnlDietary.Visible && IsDietaryOtherSelected() && string.IsNullOrWhiteSpace(rtbDietaryOther.Text))
            {
                valGuests.Text = "Please specify your other dietary restriction.";
                valGuests.Visible = true;

                // valGuests sits above a tall pnlForm inside the UpdatePanel, so an async postback
                // leaves the viewport where it was and the message goes unread -- the success path
                // below scrolls for exactly this reason. The birth date and address checks above
                // share the problem; left alone to keep this change inside PTP-18203's scope.
                ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
                return;
            }

            ShowSingleOccurrence_Accept(attendanceOccurrenceId.Value, person);
            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
        }

        protected void lbDecline_Single_Click(object sender, EventArgs e)
        {
            valGuests.Visible = false;
            valGuests.Text = string.Empty;
            valDecline.Visible = false;
            valDecline.Text = string.Empty;

            var attendanceOccurrenceId = PageParameter(PageParameterKey.AttendanceOccurrenceId).AsIntegerOrNull();

            if (!HasPersonActionIdentifier() && CurrentPerson == null && !HasRequiredPersonIdentityFields())
            {
                // User did not fulfill Name & Email fields
                valDecline.Text = "You must provide your name/email before declining.";
                valDecline.Visible = true;
                return;
            }
            else if (dpBirthDate1.Visible && dpBirthDate1.Required && !dpBirthDate1.SelectedDate.HasValue && !string.IsNullOrEmpty(dpBirthDate1.Text))
            {
                valDecline.Text = "Please enter a valid birth date in MM/DD/YYYY format.";
                valDecline.Visible = true;
                return;
            }
            else if (acAddress.Visible && acAddress.Required)
            {
                if (string.IsNullOrWhiteSpace(acAddress.Street1) || string.IsNullOrWhiteSpace(acAddress.City) ||
                    string.IsNullOrWhiteSpace(acAddress.State) || string.IsNullOrWhiteSpace(acAddress.PostalCode))
                {
                    valDecline.Text = "Please enter a complete address including street, city, state, and zip code.";
                    valDecline.Visible = true;
                    return;
                }
            }
            else if (attendanceOccurrenceId == null)
            {
                // Invalid person action identifier.
                nbNotAuthorized.Visible = true;
                return;
            }

            var person = GetPerson();
            if (person == null)
            {
                nbNotAuthorized.Visible = true;
                return;
            }



            ShowSingleOccurrence_Decline(attendanceOccurrenceId.Value, person);
            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
        }

        protected void lbAccept_Multiple_Click(object sender, EventArgs e)
        {
            if (!HasPersonActionIdentifier() && CurrentPerson == null && !HasRequiredPersonIdentityFields())
            {
                nbNoOccurrencesSelected.Text = "You must provide your name/email before accepting.";
                nbNoOccurrencesSelected.Visible = true;
                return;
            }

            var person = GetPerson();
            var attendanceOccurrenceIdList = GetMultipleOccurrenceIds();
            if (person == null || !attendanceOccurrenceIdList.Any())
            {
                // Invalid person action identifier.
                nbNotAuthorized.Visible = true;
                return;
            }

            ShowMultipleOccurrence_Accept(attendanceOccurrenceIdList, person);
            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
        }

        protected void lbSaveDeclineReason_Click(object sender, EventArgs e)
        {
            int? declineReason = rrblDeclineReasons.SelectedValueAsInt();
            if (declineReason.HasValue)
            {
                int occurrenceId = hfDeclineReason_OccurrenceId.Value.AsInteger();
                using (var rockContext = new RockContext())
                {
                    var person = GetPerson();
                    var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);
                    var occurrence = attendanceOccurrenceService.Get(occurrenceId);

                    // GetPerson() is nullable on every entry point in this block, and person.Guid is
                    // dereferenced on the next line, so it has to be checked before the reload.
                    if (person == null)
                    {
                        nbNotAuthorized.Visible = true;
                        return;
                    }

                    person = new PersonService(rockContext).Get(person.Guid);

                    // The occurrence id here arrives from a hidden field, so a page left open while the
                    // occurrence was deleted -- or a tampered field -- reaches this write path with
                    // nothing to record against, and UpdateOrCreateAttendanceRecord dereferences
                    // occurrence.Id and person.PrimaryAliasId unchecked. Returning before the write
                    // also keeps the decline-confirmation panel from claiming a save that never
                    // happened.
                    if (occurrence == null || person == null)
                    {
                        Show404();
                        return;
                    }

                    UpdateOrCreateAttendanceRecord(occurrence, person, rockContext, Rock.Model.RSVP.No, null, declineReason.Value, rtbDeclineNote.Text);
                }
                pnlDeclineReasons.Visible = false;
                pnlDeclineReasonConfirmation.Visible = true;
                ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "ScrollToTop", "setTimeout(function() { window.scrollTo(0, 0); }, 100);", true);
            }
        }
        #endregion

        #region Internal Methods

        /// <summary>
        /// Writes the email accept response when it's necessary to show the choice form.
        /// </summary>
        /// <param name="occurrenceId"></param>
        /// <param name="person"></param>
        private void WriteEmailAcceptResponse(int occurrenceId, Person person)
        {
            using (var rockContext = new RockContext())
            {
                var occurrence = new AttendanceOccurrenceService(rockContext).Get(occurrenceId);
                person = new PersonService(rockContext).Get(person.Guid);

                // UpdateOrCreateAttendanceRecord dereferences occurrence.Id and person.PrimaryAliasId
                // without checking either, so a stale Accept link from an old email threw here --
                // before ShowSingleOccurrence_Accept, which runs next, could render its "could not be
                // found" panel. There is nothing to record against an occurrence that no longer
                // exists, so returning is the entire fix.
                if (occurrence == null || person == null)
                {
                    return;
                }

                UpdateOrCreateAttendanceRecord(occurrence, person, rockContext, Rock.Model.RSVP.Yes);
            }
        }

        /// <summary>
        /// Gets the list of Occurrence IDs from the query string.
        /// </summary>
        private List<int> GetMultipleOccurrenceIds()
        {
            var attendanceOccurrenceIdList = new List<int>();
            string attendanceOccurrenceIds = PageParameter(PageParameterKey.AttendanceOccurrenceIds);
            if (!string.IsNullOrWhiteSpace(attendanceOccurrenceIds))
            {
                try
                {
                    attendanceOccurrenceIdList = attendanceOccurrenceIds.Split(',').Select(int.Parse).ToList();
                }
                catch
                {
                    /* Ignore failures to convert query string to integer values. */
                }
            }
            return attendanceOccurrenceIdList;
        }

        /// <summary>
        /// Returns a Person record for a PersonActionIdentifier for the action type "RSVP", the logged-in person, or a public RSVP form identity.
        /// </summary>
        /// <returns></returns>
        private Person GetPerson()
        {
            string personActionIdentifier = PageParameter(PageParameterKey.PersonActionIdentifier);
            if (!string.IsNullOrWhiteSpace(personActionIdentifier))
            {
                // Get Person record from PersonActionIdentifier.
                using (var rockContext = new RockContext())
                {
                    var personService = new PersonService(rockContext);
                    return personService.GetByPersonActionIdentifier(personActionIdentifier, "RSVP");
                }
            }
            else
            {
                if (CurrentPerson != null)
                {
                    return CurrentPerson;
                }

                if (!Page.IsPostBack || !HasRequiredPersonIdentityFields())
                {
                    return new Person();
                }

                return CreatePerson();
            }

        }

        /// <summary>
        /// Determines if this RSVP request is using a PersonActionIdentifier from an email link.
        /// </summary>
        private bool HasPersonActionIdentifier()
        {
            return !PageParameter(PageParameterKey.PersonActionIdentifier).IsNullOrWhiteSpace();
        }

        /// <summary>
        /// Determines if the public RSVP identity fields are complete enough to create or match a person.
        /// </summary>
        private bool HasRequiredPersonIdentityFields()
        {
            return rtbFirstName.Text.IsNotNullOrWhiteSpace()
                && rtbLastName.Text.IsNotNullOrWhiteSpace()
                && rebEmail.Text.IsNotNullOrWhiteSpace();
        }

        /// <summary>
        /// Populates the name and email controls and optionally locks them for email-based RSVP responses.
        /// </summary>
        private void PopulatePersonIdentityFields(Person person, bool isLocked)
        {
            if (person == null)
            {
                return;
            }

            rtbFirstName.Text = person.FirstName;
            rtbLastName.Text = person.LastName;
            rebEmail.Text = person.Email;

            rtbFirstName.ReadOnly = false;
            rtbLastName.ReadOnly = false;
            rebEmail.ReadOnly = false;

            rtbFirstName.Enabled = !isLocked;
            rtbLastName.Enabled = !isLocked;
            rebEmail.Enabled = !isLocked;
        }

        /// <summary>
        /// Determines if the phone field should be shown for the group. Non-176 group types always show phone,
        /// while 176 uses the group's Info_PhoneNumber flag.
        /// </summary>
        private bool ShouldShowPhoneField(Group group)
        {
            if (group == null)
            {
                return false;
            }

            group.LoadAttributes();

            return group.GroupTypeId != 176 || group.GetAttributeValue("Info_PhoneNumber").AsBoolean();
        }

        /// <summary>
        /// Applies phone field visibility/required state and prefills the person's phone when shown.
        /// </summary>
        private void ConfigurePhoneField(bool showPhoneField, Person person)
        {
            pnbPhone.Visible = showPhoneField;
            pnbPhone.Required = showPhoneField;

            if (!showPhoneField || person == null)
            {
                return;
            }

            try
            {
                var phoneNumber = new PhoneNumberService(new RockContext())
                    .GetNumberByPersonIdAndType(person.Id, "407E7E45-7B2E-4FCD-9605-ECB1339F2453");

                if (phoneNumber != null)
                {
                    pnbPhone.Number = phoneNumber.NumberFormatted;
                }
            }
            catch
            {
            }
        }

        /// <summary>
        /// Determines whether an attendance row belongs to the supplied person.
        /// </summary>
        private bool AttendanceBelongsToPerson(Attendance attendance, Person person)
        {
            if (attendance == null || person == null)
            {
                return false;
            }

            if (person.PrimaryAliasId.HasValue && attendance.PersonAliasId.HasValue)
            {
                return attendance.PersonAliasId.Value == person.PrimaryAliasId.Value;
            }

            return person.Aliases != null
                && attendance.PersonAlias != null
                && person.Aliases.Contains(attendance.PersonAlias);
        }

        /// <summary>
        /// Gets the attendance row for the supplied person.
        /// </summary>
        private Attendance GetAttendanceForPerson(AttendanceOccurrence occurrence, Person person)
        {
            if (occurrence == null || person == null)
            {
                return null;
            }

            return occurrence.Attendees.FirstOrDefault(a => AttendanceBelongsToPerson(a, person));
        }

        /// <summary>
        /// Gets the occurrence start time text, falling back to the occurrence if an attendance row has not been materialized yet.
        /// </summary>
        private string GetOccurrenceTimeText(AttendanceOccurrence occurrence, Attendance attendance)
        {
            if (attendance != null)
            {
                return attendance.StartDateTime.ToShortTimeString();
            }

            if (occurrence == null)
            {
                return string.Empty;
            }

            var startDateTime = occurrence.Schedule != null && occurrence.Schedule.HasSchedule()
                ? occurrence.OccurrenceDate.Date.Add(occurrence.Schedule.StartTimeOfDay)
                : occurrence.OccurrenceDate;

            return startDateTime.ToShortTimeString();
        }

        /// <summary>
        /// Configures the phone field for a single occurrence RSVP.
        /// </summary>
        private void ConfigurePhoneFieldForOccurrence(int occurrenceId, Person person)
        {
            using (var rockContext = new RockContext())
            {
                var occurrence = new AttendanceOccurrenceService(rockContext).Get(occurrenceId);
                ConfigurePhoneField(ShouldShowPhoneField(occurrence?.Group), person);
            }
        }

        /// <summary>
        /// Configures the phone field for a multi-occurrence RSVP if any valid occurrence requires it.
        /// </summary>
        private void ConfigurePhoneFieldForOccurrences(List<int> occurrenceIds, Person person)
        {
            bool showPhoneField = false;

            using (var rockContext = new RockContext())
            {
                var occurrenceService = new AttendanceOccurrenceService(rockContext);

                foreach (var occurrenceId in occurrenceIds)
                {
                    var occurrence = occurrenceService.Get(occurrenceId);
                    if (occurrence?.Group != null && ShouldShowPhoneField(occurrence.Group))
                    {
                        showPhoneField = true;
                        break;
                    }
                }
            }

            ConfigurePhoneField(showPhoneField, person);
        }

        /// <summary>
        /// Creates the person.
        /// </summary>
        /// <returns></returns>
        private Person CreatePerson()
        {
            var rockContext = new RockContext();

            var personService = new PersonService(rockContext);
            var personQuery = new PersonService.PersonMatchQuery(rtbFirstName.Text.Trim(), rtbLastName.Text.Trim(), rebEmail.Text.Trim(), string.Empty);
            var matchPerson = personService.FindPerson(personQuery, true);

            if (matchPerson != null)
            {
                return matchPerson;
            }
            else
            {
                DefinedValueCache dvcConnectionStatus = DefinedValueCache.Get(GetAttributeValue(AttributeKey.ConnectionStatus).AsGuid());
                DefinedValueCache dvcRecordStatus = DefinedValueCache.Get(GetAttributeValue(AttributeKey.RecordStatus).AsGuid());

                Person person = new Person();
                person.FirstName = rtbFirstName.Text;
                person.LastName = rtbLastName.Text;
                person.Email = rebEmail.Text;
                person.IsEmailActive = true;
                person.EmailPreference = EmailPreference.EmailAllowed;
                // WE WOULD NEED TO COPY THIS SECTION FOR ADDRESS + MARITAL + GENDER TO SAVE THOSE PROPERTIES TO THE PERSON WHO WAS JUST MATCHED OR CREATED

                /*
                if (!string.IsNullOrWhiteSpace(PhoneNumber.CleanNumber(pnbPhone.Number)))
                {
                    int phoneNumberTypeId = 12;

                        var phoneNumber = person.PhoneNumbers.FirstOrDefault(n => n.NumberTypeValueId == phoneNumberTypeId);
                        string oldPhoneNumber = string.Empty;
                        if (phoneNumber == null)
                        {
                            phoneNumber = new PhoneNumber { NumberTypeValueId = phoneNumberTypeId };
                            person.PhoneNumbers.Add(phoneNumber);
                        }
                        else
                        {
                            oldPhoneNumber = phoneNumber.NumberFormattedWithCountryCode;
                        }

                        phoneNumber.CountryCode = PhoneNumber.CleanNumber(pnbPhone.CountryCode);
                        phoneNumber.Number = PhoneNumber.CleanNumber(pnbPhone.Number);

                }
                
                
                if (dvpMaritalStatus1.SelectedDefinedValueId != ' ')
                    {
                person.MaritalStatusValueId = dvpMaritalStatus1.SelectedDefinedValueId.ToIntSafe();
                }

                if(rblGender.SelectedValueAsEnumOrNull<Gender>() != null)
                {
                    person.Gender = rblGender.SelectedValueAsEnum<Gender>();
                }

                if(dpBirthDate1 != null)
                {
                person.SetBirthDate(dpBirthDate1.SelectedDate);
                }
                


                
                var homeLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_HOME.AsGuid());
                if (homeLocationType != null)
                {
                    // Find a location record for the address that was entered
                    var loc = new Location();
                    acAddress.GetValues(loc);
                    if (acAddress.Street1.IsNotNullOrWhiteSpace() && loc.City.IsNotNullOrWhiteSpace())
                    {
                        loc = new LocationService( rockContext ).Get(
                            loc.Street1, loc.Street2, loc.City, loc.State, loc.PostalCode, loc.Country, true);
                    }
                    else
                    {
                        loc = null;
                    }

                    // Check to see if family has an existing home address
                    var primaryFamily = person.PrimaryFamily;
                    var groupLocation = primaryFamily.GroupLocations
                        .FirstOrDefault(l =>
                           l.GroupLocationTypeValueId.HasValue &&
                           l.GroupLocationTypeValueId.Value == homeLocationType.Id);

                    if (loc != null)
                    {
                        if (groupLocation == null || groupLocation.LocationId != loc.Id)
                        {
                            // If family does not currently have a home address or it is different than the one entered, add a new address (move old address to prev)
                            GroupService.AddNewGroupAddress(rockContext, primaryFamily, homeLocationType.Guid.ToString(), loc, true, string.Empty, true, true);
                        }
                    }
                    else
                    {
                        if (groupLocation != null)
                        {
                            // If an address was not entered, and family has one on record, update it to be a previous address
                            var prevLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_PREVIOUS.AsGuid());
                            if (prevLocationType != null)
                            {
                                groupLocation.GroupLocationTypeValueId = prevLocationType.Id;
                            }
                        }
                    }
                }
                */

                person.RecordTypeValueId = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.PERSON_RECORD_TYPE_PERSON.AsGuid()).Id;
                if (dvcConnectionStatus != null)
                {
                    person.ConnectionStatusValueId = dvcConnectionStatus.Id;
                }

                if (dvcRecordStatus != null)
                {
                    person.RecordStatusValueId = dvcRecordStatus.Id;
                }

                PersonService.SaveNewPerson(person, rockContext, null, false);

                return person;

            }


        }

        /// <summary>
        /// Display a "not found" message for actions which cannot be performed.
        /// </summary>
        /// <param name="PageTitle">The optional page title to display.</param>
        private void Show404(bool isExpired = false, string PageTitle = "")
        {
            //Context.Response.StatusCode = 404;
            pnl404.Visible = true;
            pnlForm.Visible = false;
            pnlMultiple_Accept.Visible = false;
            pnlMultiple_Choice.Visible = false;
            pnlSingle_Accept.Visible = false;
            pnlSingle_Choice.Visible = false;
            pnlSingle_Decline.Visible = false;

            if (isExpired)
            {
                if (string.IsNullOrWhiteSpace(PageTitle))
                {
                    pnlHeading.Visible = false;
                }
                else
                {
                    lHeading.Text = PageTitle;
                }

                nbExpired.Visible = true;
            }
            else
            {
                pnlHeading.Visible = false;
                nbNotFound.Visible = true;
            }
        }

        #region Dietary Restrictions (PTP-18203)

        /// <summary>
        /// The "Other" option within the Dietary Restrictions DefinedType (346).
        /// </summary>
        private const string DietaryOtherValueGuid = "246898C7-9502-4845-81C1-055AD223BB5C";

        /// <summary>
        /// Group attribute that opts an event into the Dietary Restrictions fields. This is a Boolean on
        /// the "Events" group type, so an administrator controls it per event from the group itself.
        /// The original implementation also required the event to be parented to group 1192535 -- the
        /// group literally named "_testing" -- which the PTP-18203 ticket does not ask for. That check
        /// was removed: it made ticking this box on any real event a silent no-op, with nothing in the
        /// UI to explain why the fields never appeared.
        /// </summary>
        private const string DietaryEnabledAttributeKey = "Info_DietaryRestrictions";

        /// <summary>
        /// Person attribute keys for Dietary Restrictions. These are Person attributes, NOT GroupMember.
        /// "DietaryRestrictions" is a multi-select Defined Value on DefinedType 346 and stores
        /// comma-delimited DefinedValue GUIDs. "OtherDietaryRestriction" is its free-text companion.
        /// The plural/singular mismatch is how the two already exist in the database. SetAttributeValue
        /// does nothing at all when a key does not match an attribute, so these must stay exact.
        /// </summary>
        private const string DietaryRestrictionsAttributeKey = "DietaryRestrictions";

        private const string DietaryOtherAttributeKey = "OtherDietaryRestriction";

        /// <summary>
        /// Registers the script that reveals the Dietary Restrictions "Other" text box when the
        /// "Other" option is checked.
        /// This replaces an AutoPostBack round trip: AutoPostBack on the DefinedValuesPicker tripped
        /// ASP.NET event validation and returned a 500 on every checkbox click (PTP-18203).
        /// </summary>
        private void RegisterDietaryOtherRevealScript()
        {
            // ASP.NET CheckBoxList does not render an item's value onto the input element, so the
            // "Other" checkbox has to be matched on its label text instead.
            var otherDefinedValue = GetDietaryOtherDefinedValue();
            var otherLabel = otherDefinedValue != null ? otherDefinedValue.Value : "Other";

            var script = @"
(function () {
    'use strict';

    var otherLabel = '" + otherLabel.Replace("\\", "\\\\").Replace("'", "\\'") + @"';

    function isOtherChecked() {
        var found = false;
        $('.js-dietary-picker input[type=checkbox]:checked').each(function () {
            if ($.trim($('label[for=""' + this.id + '""]').text()) === otherLabel) { found = true; }
        });
        return found;
    }

    // No validator toggling here on purpose. rtbDietaryOther is not declared Required, because
    // RockControlHelper re-forces RequiredFieldValidator.Enabled = true at render whenever Required
    // is set, which would undo a client-side ValidatorEnable(false). The requirement is enforced
    // server-side in lbAccept_Single_Click instead.
    function sync(animate) {
        var $other = $('.js-dietary-other');
        if (!$other.length) { return; }

        var show = isOtherChecked();
        if (show) {
            if (animate) { $other.slideDown(150); } else { $other.show(); }
        } else {
            if (animate) { $other.slideUp(150); } else { $other.hide(); }
            // The box keeps its value on purpose. Clearing it here wiped a pre-filled value the
            // moment 'Other' was unchecked -- and sync(false) also runs on add_endRequest, so
            // every async postback wiped it too. SaveDietaryRestrictions stores string.Empty
            // when 'Other' is not selected, so a hidden leftover is never persisted.
        }
    }

    // Delegated from document so the handler survives the UpdatePanel replacing the DOM.
    // off() runs first because RegisterStartupScript re-emits this on every async postback.
    $(document).off('change.rsvpDietary').on('change.rsvpDietary', '.js-dietary-picker input[type=checkbox]', function () {
        sync(true);
    });

    $(function () { sync(false); });

    if (typeof Sys !== 'undefined' && Sys.WebForms && Sys.WebForms.PageRequestManager && !window.rsvpDietaryHooked) {
        window.rsvpDietaryHooked = true;
        Sys.WebForms.PageRequestManager.getInstance().add_endRequest(function () { sync(false); });
    }
})();
";
            ScriptManager.RegisterStartupScript(this.Page, this.Page.GetType(), "DietaryOtherRevealScript", script, true);
        }

        /// <summary>
        /// Gets the "Other" Dietary Restrictions DefinedValue, or null when it cannot be found.
        /// </summary>
        private DefinedValueCache GetDietaryOtherDefinedValue()
        {
            return DefinedValueCache.Get(DietaryOtherValueGuid.AsGuid());
        }

        /// <summary>
        /// Determines whether the "Other" dietary option is currently selected in the picker.
        /// </summary>
        private bool IsDietaryOtherSelected()
        {
            var otherDefinedValue = GetDietaryOtherDefinedValue();

            return otherDefinedValue != null
                && dvpDietaryRestrictions.SelectedValues.Contains(otherDefinedValue.Id.ToString());

        }

        /// <summary>
        /// Determines whether the Dietary Restrictions fields apply to the given group.
        /// </summary>
        private bool IsDietaryEnabled(Group group)
        {
            if (group == null)
            {
                return false;
            }

            if (group.Attributes == null)
            {
                group.LoadAttributes();
            }

            return group.GetAttributeValue(DietaryEnabledAttributeKey).AsBoolean();
        }

        /// <summary>
        /// Shows or hides the Dietary Restrictions fields, and loads the person's saved values.
        /// </summary>
        private void ConfigureDietaryRestrictions(Group group, Person person)
        {
            pnlDietary.Visible = IsDietaryEnabled(group);

            if (!pnlDietary.Visible || person == null)
            {
                return;
            }

            person.LoadAttributes();

            var savedIds = person.GetAttributeValue(DietaryRestrictionsAttributeKey)
                .SplitDelimitedValues()
                .Select(guid => DefinedValueCache.Get(guid.AsGuid()))
                .Where(definedValue => definedValue != null)
                .Select(definedValue => definedValue.Id)
                .ToList();

            var savedOtherText = person.GetAttributeValue(DietaryOtherAttributeKey);
            var otherDefinedValue = GetDietaryOtherDefinedValue();

            // Some existing records carry "Other" text without the "Other" option selected. Left as
            // stored, the picker renders "Other" unchecked and SaveDietaryRestrictions then writes
            // string.Empty -- silently destroying text the person was never shown. Selecting "Other"
            // makes the loaded state self-consistent, so the text is visible and only ever cleared
            // deliberately.
            if (savedOtherText.IsNotNullOrWhiteSpace()
                && otherDefinedValue != null
                && !savedIds.Contains(otherDefinedValue.Id))
            {
                savedIds.Add(otherDefinedValue.Id);
            }

            if (savedIds.Any())
            {
                dvpDietaryRestrictions.SelectedDefinedValuesId = savedIds.ToArray();
            }

            rtbDietaryOther.Text = savedOtherText;
        }

        /// <summary>
        /// Saves the Dietary Restrictions selections onto the person.
        /// </summary>
        private void SaveDietaryRestrictions(Person person)
        {
            if (!pnlDietary.Visible || person == null)
            {
                return;
            }

            var selectedGuids = dvpDietaryRestrictions.SelectedDefinedValuesId
                .Select(id => DefinedValueCache.Get(id))
                .Where(definedValue => definedValue != null)
                .Select(definedValue => definedValue.Guid.ToString())
                .ToList();

            // LoadAttributes is required because SetAttributeValue silently does nothing when the
            // attributes have not been loaded. SaveAttributeValues is required because
            // RockContext.SaveChanges does not persist attribute values.
            person.LoadAttributes();

            // A stored Guid that no longer resolves to a DefinedValue cannot be rendered as a
            // checkbox, so it never posts back and would be dropped here. Carry those through
            // untouched rather than deleting data this block is simply unable to display.
            var unresolvedGuids = person.GetAttributeValue(DietaryRestrictionsAttributeKey)
                .SplitDelimitedValues()
                .Where(guid => guid.IsNotNullOrWhiteSpace() && DefinedValueCache.Get(guid.AsGuid()) == null)
                .ToList();

            person.SetAttributeValue(DietaryRestrictionsAttributeKey, string.Join(",", selectedGuids.Union(unresolvedGuids)));
            person.SetAttributeValue(DietaryOtherAttributeKey, IsDietaryOtherSelected() ? rtbDietaryOther.Text : string.Empty);
            person.SaveAttributeValues();
        }

        #endregion

        /// <summary>
        /// Calculates the display title for an <see cref="AttendanceOccurrence"/>.
        /// </summary>
        /// <param name="occurrence">The <see cref="AttendanceOccurrence"/>.</param>
        private string GetOccurrenceTitle(AttendanceOccurrence occurrence)
        {
            bool hasTitle = (!string.IsNullOrWhiteSpace(occurrence.Name));
            bool hasSchedule = (occurrence.Schedule != null);

            if (hasSchedule)
            {
                // This block is unnecessary if the event has a name (because the name will take priority over the schedule, anyway), but it
                // has been intentionally left in place to prevent anyone from creating an unintentional bug in the future, as it affects
                // the logic below.
                Ical.Net.CalendarComponents.CalendarEvent calendarEvent = occurrence.Schedule.GetICalEvent();
                if (calendarEvent == null)
                {
                    hasSchedule = false;
                }
            }

            if (hasTitle)
            {
                return occurrence.Name;
            }
            else if (hasSchedule)
            {
                return string.Format(
                    "{0} - {1}, {2}",
                    occurrence.Group.Name,
                    occurrence.OccurrenceDate.ToString("dddd, MMMM d, yyyy"),
                    occurrence.Schedule.GetICalEvent().DtStart.AsSystemLocal.TimeOfDay.ToTimeString());
            }
            else
            {
                return string.Format(
                    "{0} - {1}",
                    occurrence.Group.Name,
                    occurrence.OccurrenceDate.ToString("dddd, MMMM d, yyyy"));
            }
        }

        /// <summary>
        /// Shows the Accept/Decline options to allow RSVP for a single occurrence.
        /// </summary>
        /// <param name="occurrenceId">The ID of the AttendanceOccurrence.</param>
        /// <param name="person">The Person record of the respondent.</param>
        private void ShowSingleOccurrence_Choice(int occurrenceId, Person person)
        {
            using (var rockContext = new RockContext())
            {
                var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);
                var occurrence = attendanceOccurrenceService.Get(occurrenceId);

                // A link to an occurrence that no longer exists -- a stale invitation email being
                // the common case -- arrives here with nothing to look up, and dereferencing it
                // threw a NullReferenceException that took down the whole page instead of letting
                // the block explain itself. ShowSingleOccurrence_Accept already handles this with
                // Show404, which shows the "could not be found" panel; match it.
                if (occurrence == null || occurrence.Group == null)
                {
                    Show404();
                    return;
                }

                var group = occurrence.Group;
                group.LoadAttributes();
                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                // groupMember.LoadAttributes();
                occurrence.LoadAttributes();
                var activeMembers = group.ActiveMembers().Count();
                var attendees = occurrence.Attendees;
                var members = group.ActiveMembers();
                var allowGuest = group.GetAttributeValue("Info_AllowForGuests")?.AsBoolean();
                var acceptedRSVPs = occurrence.Attendees.Where(a => a.RSVP == Rock.Model.RSVP.Yes).Count();
                var occClosedDate = occurrence.GetAttributeValue("ClosedDate")?.AsDateTime();
                int totalGuests = 0;
                // Calculate number of guests from attendees and set remaining capacity
                if (allowGuest == true)
                {
                    foreach (var a in attendees)
                    {
                        foreach (GroupMember gm in members)
                        {
                            gm.LoadAttributes();
                            int gc = gm.GetAttributeValue("GuestCount1").ToIntSafe();
                            if (AttendanceBelongsToPerson(a, gm.Person))
                            {
                                totalGuests += gc;
                                if (gm.PersonId == person.Id)
                                {
                                    totalGuests -= gc;
                                }
                            }
                        }
                    }
                    // Set the new acceptedRSVPs variable based on confirmed guests
                    acceptedRSVPs += totalGuests;
                }
                int? remainingCapacity = group.GroupCapacity - acceptedRSVPs;

                if (occClosedDate == null)
                {
                    occClosedDate = occurrence.OccurrenceDate.EndOfDay();
                }

                if (occurrence == null)
                {
                    Show404();
                    return;
                }
                else if (occClosedDate < RockDateTime.Now || acceptedRSVPs >= group.GroupCapacity)
                {
                    // This event has expired.
                    Show404(true, GetOccurrenceTitle(occurrence));
                    return;
                }

                // lHeading.Text = $"{acceptedRSVPs} // {remainingCapacity}";
                lHeading.Text = GetOccurrenceTitle(occurrence);
                pnlSingle_Choice.Visible = true;


                if (groupMember == null)
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                }

                bool displayForm = GetAttributeValue(AttributeKey.DisplayFormWhenSignedIn).AsBoolean();
                pnlForm.Visible = (CurrentPersonId == null || displayForm);

                PopulatePersonIdentityFields(person, HasPersonActionIdentifier());




                // This collection object is created to limit attribute values to those marked "IsPublic".
                var publicAttributes = new GroupMemberPublicAttriuteCollection(groupMember);

                if (publicAttributes.Attributes.Any())
                {
                    Helper.AddEditControls(publicAttributes, phAttributes, true);
                }

                // This collection object is created to find which person fields are enabled through group attributes marked as boolean 'true'


                var pncheck = ShouldShowPhoneField(group);
                var adrcheck = group.GetAttributeValue("Info_Address").AsBoolean();
                var gndcheck = group.GetAttributeValue("Info_Gender").AsBoolean();
                var mscheck = group.GetAttributeValue("Info_MaritalStatus").AsBoolean();
                var bdcheck = group.GetAttributeValue("Info_BirthDate").AsBoolean();


                ConfigurePhoneField(pncheck, person);

                if (adrcheck)
                {
                    acAddress.Visible = true;
                    acAddress.Required = true;
                    Group family = null;
                    Person adult1 = null;
                    Person adult2 = null;

                    // If there is a logged in person, attempt to find their family and spouse.
                    if (person != null)
                    {
                        Person spouse = null;

                        // Get all their families
                        var families = person.GetFamilies(rockContext);
                        if (families.Any())
                        {
                            // Get their spouse
                            spouse = person.GetSpouse(rockContext);
                            if (spouse != null)
                            {
                                // If spouse was found, find the first family that spouse belongs to also.
                                family = families.Where(f => f.Members.Any(m => m.PersonId == spouse.Id)).FirstOrDefault();
                                if (family == null)
                                {
                                    // If there was not family with spouse, something went wrong and assume there is no spouse.
                                    spouse = null;
                                }
                            }

                            // If we didn't find a family yet (by checking spouses family), assume the first family.
                            if (family == null)
                            {
                                family = families.FirstOrDefault();
                            }

                            // Assume Adult1 is the current person
                            adult1 = person;
                            if (spouse != null)
                            {
                                // and Adult2 is the spouse
                                adult2 = spouse;

                                // However, if spouse is actually head of family, make them Adult1 and current person Adult2
                                var headOfFamilyId = family.Members
                                    .OrderBy(m => m.GroupRole.Order)
                                    .ThenBy(m => m.Person.Gender)
                                    .Select(m => m.PersonId)
                                    .FirstOrDefault();
                                if (headOfFamilyId != 0 && headOfFamilyId == spouse.Id)
                                {
                                    adult1 = spouse;
                                    adult2 = person;
                                }
                            }
                        }

                        if (family != null)
                        {

                            // Set the address from the family
                            var homeLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_HOME.AsGuid());
                            if (homeLocationType != null)
                            {
                                var location = family.GroupLocations
                                    .Where(l =>
                                       l.GroupLocationTypeValueId.HasValue &&
                                       l.GroupLocationTypeValueId.Value == homeLocationType.Id)
                                    .Select(l => l.Location)
                                    .FirstOrDefault();
                                acAddress.SetValues(location);
                            }
                            else
                            {
                                acAddress.SetValues(null);
                            }
                        }
                    }
                }

                if (gndcheck)
                {
                    rblGender.Visible = true;
                    rblGender.Required = true;
                    rblGender.SetValue(person != null ? person.Gender.ConvertToInt() : 0);


                }

                if (mscheck)
                {
                    dvpMaritalStatus1.Visible = true;
                    dvpMaritalStatus1.Required = true;
                    try
                    {
                        dvpMaritalStatus1.SelectedDefinedValueId = person.MaritalStatusValueId;
                    }
                    catch
                    {

                    }
                }

                if (bdcheck)
                {
                    dpBirthDate1.Visible = true;
                    dpBirthDate1.Required = true;
                    try
                    {
                        if (person.BirthDate.HasValue)
                        {
                            dpBirthDate1.SelectedDate = person.BirthDate;
                        }
                    }
                    catch
                    {

                    }
                }

                if (allowGuest == true)
                {
                    divGuestCount.Visible = true;
                }

                // Dietary Restrictions (PTP-18203). pnlDietary wraps both the picker and the "Other"
                // box so a single flag gates the pair. The "Other" box stays visible server-side and
                // is hidden by its wrapper div, so script can reveal it without a postback.
                ConfigureDietaryRestrictions(group, person);
            }
        }
        /// <summary>
        /// Rebuilds the dynamic attribute value controls (for single occurrence mode) after a postback.
        /// </summary>
        private void BuildAttributeControls()
        {
            using (var rockContext = new RockContext())
            {
                var person = GetPerson();
                var occurrenceId = PageParameter(PageParameterKey.AttendanceOccurrenceId).AsInteger();
                var occurrence = new AttendanceOccurrenceService(rockContext).Get(occurrenceId);

                // The mirror of the guard in GroupHasAttributes below. This rebuilds the same controls
                // after a postback and dereferences occurrence.Group and person.Id the same way, so it
                // failed the same way. With nothing to build against, leaving the placeholder empty is
                // correct -- the caller's own missing-occurrence handling renders the message.
                if (occurrence == null || occurrence.Group == null || person == null)
                {
                    return;
                }

                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                if (groupMember == null)
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                }
                var publicAttributes = new GroupMemberPublicAttriuteCollection(groupMember);
                if (publicAttributes.Attributes.Any())
                {
                    Helper.AddEditControls(publicAttributes, phAttributes, false);
                }
            }
        }

        /// <summary>
        /// Tests the group to see if there are any GroupMember attributes.
        /// </summary>
        /// <returns></returns>
        private bool GroupHasAttributes()
        {
            using (var rockContext = new RockContext())
            {
                var person = GetPerson();
                var occurrenceId = PageParameter(PageParameterKey.AttendanceOccurrenceId).AsInteger();
                var occurrence = new AttendanceOccurrenceService(rockContext).Get(occurrenceId);

                // This runs before anything else on the Accept path, so an unguarded dereference here
                // crashed the page first and made every downstream guard unreachable. With no group
                // there are no public group-member attributes to collect, so false is the honest
                // answer and it lets the caller fall through to the "could not be found" panel.
                if (occurrence == null || occurrence.Group == null || person == null)
                {
                    return false;
                }

                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                if (groupMember == null)
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                }

                groupMember.LoadAttributes();
                var publicAttributes = new GroupMemberPublicAttriuteCollection(groupMember);
                return publicAttributes.Attributes.Any();
            }
        }

        /// <summary>
        /// Shows the RSVP Accept message for a single occurrence.
        /// </summary>
        /// <param name="occurrenceId">The ID of the AttendanceOccurrence.</param>
        /// <param name="person">The Person record of the respondent.</param>

        private void ShowSingleOccurrence_Accept(int occurrenceId, Person person)
        {
            using (var rockContext = new RockContext())
            {
                var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);
                var occurrence = attendanceOccurrenceService.Get(occurrenceId);
                if (occurrence == null)
                {
                    Show404();
                    return;
                }

                var group = occurrence.Group;
                if (group == null)
                {
                    Show404();
                    return;
                }

                group.LoadAttributes();
                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                // Set Closed Date based on occurrence info
                occurrence.LoadAttributes();
                var occClosedDate = occurrence.GetAttributeValue("ClosedDate")?.AsDateTime();
                if (occClosedDate == null)
                {
                    occClosedDate = occurrence.OccurrenceDate.EndOfDay();
                }

                // Load members and attendees
                var members = group.ActiveMembers();
                var activeMembers = group.ActiveMembers().Count();
                var attendees = occurrence.Attendees;

                var allowGuest = group.GetAttributeValue("Info_AllowForGuests")?.AsBoolean();
                int acceptedRSVPs = occurrence.Attendees.Where(a => a.RSVP == Rock.Model.RSVP.Yes).Count();
                int totalGuests = 0;
                int guestCount = rnbGuestCount.IntegerValue.ToIntSafe() + 1; //Add one to include the person who submits

                // Calculate number of guests from attendees and set remaining capacity
                if (allowGuest == true)
                {
                    foreach (var a in attendees)
                    {
                        foreach (GroupMember gm in members)
                        {
                            gm.LoadAttributes();
                            int gc = gm.GetAttributeValue("GuestCount1").ToIntSafe();
                            if (AttendanceBelongsToPerson(a, gm.Person))
                            {
                                totalGuests += gc;
                                // If person already exists, don't count their guest count attribute
                                if (gm.PersonId == person.Id)
                                {
                                    totalGuests -= gc;
                                    acceptedRSVPs -= 1;
                                }
                            }
                        }
                    }

                    acceptedRSVPs += totalGuests;
                }
                int? remainingCapacity = group.GroupCapacity - acceptedRSVPs;

                // Display result based on capacity or date
                if (occurrence == null)
                {
                    Show404();
                    return;
                }
                else if (occClosedDate < RockDateTime.Now || acceptedRSVPs >= group.GroupCapacity)
                {
                    // This event has expired or run out of capacity
                    Show404(true, GetOccurrenceTitle(occurrence));
                    return;
                }
                else if (guestCount > remainingCapacity)
                {
                    // There isn't enough space for you and your guests
                    valGuests.Text = $"This event has room for {remainingCapacity} more people.";
                    valGuests.Visible = true;
                    return;
                }

                valGuests.Visible = false;
                valDecline.Visible = false;

                lHeading.Text = GetOccurrenceTitle(occurrence);

                person = new PersonService(rockContext).Get(person.Guid);
                UpdateOrCreateAttendanceRecord(occurrence, person, rockContext, Rock.Model.RSVP.Yes, phAttributes);

                var attendance = GetAttendanceForPerson(occurrence, person);

                // Show Single Occurrence Accept message.
                pnlSingle_Accept.Visible = true;
                pnlSingle_Choice.Visible = false;
                pnlForm.Visible = false;

                var occurrenceDateText = occurrence.OccurrenceDate.ToShortDateString();
                var occurrenceTimeText = GetOccurrenceTimeText(occurrence, attendance);
                var mergeFields = Rock.Lava.LavaHelper.GetCommonMergeFields(RockPage, person);
                mergeFields.Add("OccurrenceName", occurrence.Name);
                mergeFields.Add("Person", person);
                mergeFields.Add("OccurrenceDate", occurrenceDateText);
                mergeFields.Add("OccurrenceTime", occurrenceTimeText);
                mergeFields.Add("OccurrenceStartDate", occurrenceDateText);
                mergeFields.Add("OccurrenceStartTime", occurrenceTimeText);
                if (allowGuest == true)
                {
                    mergeFields.Add("GuestCount", rnbGuestCount.IntegerValue);
                }

                //// Send Confirmation Message from Group Type (not ideal... have to revise)

                occurrence.Group.LoadAttributes(rockContext);
                if (occurrence.Group.GroupTypeId == 176)
                {
                    var sendemail = group.GetAttributeValue("Comm_SendConfirmation")?.AsBoolean() ?? false;
                    var email_content = group.GetAttributeValue("Comm_ConfirmationEmail") ?? null;
                    if (email_content != null)
                    {
                        email_content = email_content.Replace("/GetImage.ashx?", "https://connect.passion.team/GetImage.ashx?");
                        email_content = new StructuredContentHelper(email_content).Render();
                        email_content = email_content.Replace("<img ", "<img style='width: 100%;'");
                    }
                    if (sendemail == true && email_content != null)
                    {
                        // Pull Email Fields from Group
                        var fromName = group.GetAttributeValue("Comm_FromName");
                        var fromEmail = group.GetAttributeValue("Comm_FromEmail");
                        var replyToEmail = group.GetAttributeValue("Comm_ReplyToEmail");
                        var emailSubject = group.GetAttributeValue("Comm_EmailSubject");

                        var message = new RockEmailMessage();
                        message.AddRecipient(new RockEmailMessageRecipient(person, mergeFields));
                        message.Message = email_content;
                        message.AdditionalMergeFields = mergeFields;
                        // All four of these were inverted: the blank branch returned the blank value
                        // and the configured branch was discarded. So a group's Comm_* settings never
                        // took effect, and a group with nothing configured sent a blank From and a
                        // blank Subject. Configured value wins; the literal is the fallback.
                        message.FromName = fromName.IsNullOrWhiteSpace() ? "Passion City Church" : fromName;
                        message.FromEmail = fromEmail.IsNullOrWhiteSpace() ? "connect@passioncitychurch.com" : fromEmail;
                        message.ReplyToEmail = replyToEmail.IsNullOrWhiteSpace() ? "connect@passioncitychurch.com" : replyToEmail;
                        message.Subject = emailSubject.IsNullOrWhiteSpace() ? "RSVP Confirmed — " + group.Name : emailSubject;

                        message.AppRoot = ResolveRockUrl("~/");
                        message.ThemeRoot = ResolveRockUrl("~~/");
                        message.CreateCommunicationRecord = true;
                        message.Send();
                        rockContext.SaveChanges();
                    }
                }
                else
                {
                    var emailTemplate = group.GetAttributeValue("EmailTemplate");
                    if (!string.IsNullOrEmpty(emailTemplate))
                    {
                        var communicationTemplate = new CommunicationTemplateService(rockContext).Get(emailTemplate.AsGuid());
                        var message = new RockEmailMessage();
                        message.AddRecipient(new RockEmailMessageRecipient(person, mergeFields));
                        message.AdditionalMergeFields = mergeFields;

                        if (communicationTemplate != null)
                        {
                            message.Message = communicationTemplate.Message;
                            message.FromEmail = communicationTemplate.FromEmail;
                            if (string.IsNullOrEmpty(message.FromEmail))
                            {
                                message.FromEmail = "connect@passioncitychurch.com";
                            }
                            message.FromName = communicationTemplate.FromName;
                            if (string.IsNullOrEmpty(message.FromName))
                            {
                                message.FromName = "Passion City Church";
                            }
                            message.Subject = communicationTemplate.Subject;
                            if (string.IsNullOrEmpty(message.Subject))
                            {
                                message.Subject = occurrence.Name;
                            }
                        }
                        else
                        {
                            message.Message = emailTemplate.ResolveMergeFields(mergeFields);
                            message.FromEmail = "connect@passioncitychurch.com";
                            message.FromName = "Passion City Church";
                            message.Subject = group.GetAttributeValue("EmailSubjectLine").ResolveMergeFields(mergeFields);
                            if (string.IsNullOrEmpty(message.Subject))
                            {
                                message.Subject = occurrence.Name;
                            }
                        }

                        if (!string.IsNullOrEmpty(message.Message))
                        {
                            message.AppRoot = ResolveRockUrl("~/");
                            message.ThemeRoot = ResolveRockUrl("~~/");
                            message.CreateCommunicationRecord = true;
                            message.Send();
                            rockContext.SaveChanges();
                        }
                    }
                }

                if (!string.IsNullOrEmpty(occurrence.AcceptConfirmationMessage))
                {
                    nbAccept.Text = occurrence.AcceptConfirmationMessage.ResolveMergeFields(mergeFields);
                }
                else
                {
                    nbAccept.Text = GetAttributeValue(AttributeKey.DefaultAcceptMessage).ResolveMergeFields(mergeFields);
                }

                Authorization.SignOut();
            }
        }

        /// <summary>
        /// Creates a new attendance record or updates an existing one if it already exists.
        /// </summary>
        /// <param name="occurrence">The AttendanceOccurrence record.</param>
        /// <param name="person">The Person record.</param>
        /// <param name="rockContext">The RockContext</param>
        /// <param name="rsvpStatus">The Rock.Model.RSVP enum value to set.</param>
        /// <param name="attributePlaceHolder">(Optional) PlaceHolder control that contains the GroupMember attribute values to set.</param>
        /// <param name="declineReasonId">(Optional) The DefinedValue ID of a Decline Reason, if one was selected.  Only used if rsvpStatus is No.</param>
        /// <param name="declineNote">(Optional) An explanation of the reason for declining.  Only used if rsvpStatus is No.</param>
        private void UpdateOrCreateAttendanceRecord(AttendanceOccurrence occurrence, Person person, RockContext rockContext, Rock.Model.RSVP rsvpStatus, PlaceHolder attributePlaceHolder = null, int declineReasonId = 0, string declineNote = "")
        {
            var attendance = GetAttendanceForPerson(occurrence, person);
            if (attendance == null)
            {
                attendance = new Attendance();
                attendance.OccurrenceId = occurrence.Id;
                attendance.PersonAliasId = person.PrimaryAliasId;
                attendance.DidAttend = false;
                attendance.StartDateTime = occurrence.Schedule != null && occurrence.Schedule.HasSchedule() ? occurrence.OccurrenceDate.Date.Add(occurrence.Schedule.StartTimeOfDay) : occurrence.OccurrenceDate;
                occurrence.Attendees.Add(attendance);
            }
            attendance.RSVP = rsvpStatus;
            attendance.RSVPDateTime = DateTime.Now;
            if (rsvpStatus == Rock.Model.RSVP.No)
            {
                if (declineReasonId != 0)
                {
                    attendance.DeclineReasonValueId = declineReasonId;
                }
                attendance.Note = declineNote;

                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                if (groupMember == null)
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;

                    new GroupMemberService(rockContext).Add(groupMember);
                    rockContext.SaveChanges();
                }
                groupMember.GroupMemberStatus = GroupMemberStatus.Inactive;

            }

            // Note that GroupMember attributes are being set, here.  If this control saves multiple attendance records for a same group (e.g., the same group meets on multiple dates and the user RSVPs to
            // more than one) it will overwrite values.
            if ((attributePlaceHolder != null) && (rsvpStatus == Rock.Model.RSVP.Yes))
            {
                var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                if (groupMember == null)
                {
                    groupMember = new GroupMember();
                    groupMember.PersonId = person.Id;
                    groupMember.GroupId = occurrence.Group.Id;
                    groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;

                    new GroupMemberService(rockContext).Add(groupMember);
                    rockContext.SaveChanges();
                }
                groupMember.GroupMemberStatus = GroupMemberStatus.Active;



                groupMember.LoadAttributes();

                if (rnbGuestCount.IntegerValue > 0)
                {
                    groupMember.SetAttributeValue("GuestCount1", rnbGuestCount.IntegerValue);
                }

                Helper.GetEditValues(attributePlaceHolder, groupMember);

                groupMember.SaveAttributeValues();
            }

            // Dietary Restrictions (PTP-18203) are stored on the Person, so they are saved here rather
            // than inside UpdatePersonRecord. That method only runs when there is no
            // PersonActionIdentifier, which means it never runs for the RSVP links sent out by email.
            SaveDietaryRestrictions(person);

            if (!HasPersonActionIdentifier())
            {
                UpdatePersonRecord(person);
            }

            rockContext.SaveChanges();
        }

        /// <summary>
        /// Shows the RSVP Decline message for a single occurrence.
        /// </summary>
        /// <param name="occurrenceId">The ID of the AttendanceOccurrence.</param>
        /// <param name="person">The Person record of the respondent.</param>
        private void ShowSingleOccurrence_Decline(int occurrenceId, Person person)
        {
            using (var rockContext = new RockContext())
            {
                var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);
                var occurrence = attendanceOccurrenceService.Get(occurrenceId);

                // This null check used to sit *below* the two lines that follow it, where it could
                // never run: GetAttributeValue and GetOccurrenceTitle both dereference occurrence
                // and threw first. Checking before the first dereference is what makes the Show404
                // the original author clearly intended actually reachable.
                if (occurrence == null)
                {
                    Show404();
                    return;
                }

                var occClosedDate = occurrence.GetAttributeValue("ClosedDate").AsDateTime();
                lHeading.Text = GetOccurrenceTitle(occurrence);
                if (occClosedDate < RockDateTime.Now)
                {
                    // This event has expired.
                    Show404(true, GetOccurrenceTitle(occurrence));
                    return;
                }

                pnlForm.Visible = false;
                pnlSingle_Choice.Visible = false;
                valDecline.Visible = false;


                person = new PersonService(rockContext).Get(person.Guid);
                if (person == null)
                {
                    return;
                }
                else
                {
                    UpdateOrCreateAttendanceRecord(occurrence, person, rockContext, Rock.Model.RSVP.No);
                }
                hfDeclineReason_OccurrenceId.Value = occurrenceId.ToString();

                // Show Single Occurrence Decline form.
                pnlSingle_Decline.Visible = true;


                var mergeFields = Rock.Lava.LavaHelper.GetCommonMergeFields(RockPage, CurrentPerson);
                if (!string.IsNullOrEmpty(occurrence.DeclineConfirmationMessage))
                {
                    nbDecline.Text = occurrence.DeclineConfirmationMessage.ResolveMergeFields(mergeFields);
                }
                else
                {
                    nbDecline.Text = GetAttributeValue(AttributeKey.DefaultDeclineMessage).ResolveMergeFields(mergeFields);
                }

                if (occurrence.ShowDeclineReasons == true)
                {
                    // Show Decline Reasons.
                    string declineReasons = occurrence.DeclineReasonValueIds;
                    if (string.IsNullOrWhiteSpace(declineReasons))
                    {
                        // Use default decline reasons (block setting).
                        declineReasons = GetAttributeValue(AttributeKey.DefaultDeclineReasons);
                    }

                    var declineReasonValues = GetDeclineReasons(declineReasons);
                    if (declineReasonValues.Any())
                    {
                        rrblDeclineReasons.DataSource = declineReasonValues;
                        rrblDeclineReasons.DataBind();
                        pnlDeclineReasons.Visible = true;
                    }
                    else
                    {
                        pnlDeclineReasons.Visible = false;
                    }
                }
            }
        }

        protected class OccurrenceDataItem
        {
            public string Title { get; set; }
            public string OccurrenceId { get; set; }
            public GroupMemberPublicAttriuteCollection PublicAttributes { get; set; }
        };

        /// <summary>
        /// Shows the Accept/Decline options to allow RSVP for muiltiple occurrences.
        /// </summary>
        /// <param name="occurrenceIds">The List of IDs of the AttendanceOccurrences.</param>
        /// <param name="person">The Person record of the respondent.</param>
        private void ShowMultipleOccurrence_Choice(List<int> occurrenceIds, Person person)
        {
            lHeading.Text = GetAttributeValue(AttributeKey.MultigroupModeRSVPTitle);

            bool displayForm = GetAttributeValue(AttributeKey.DisplayFormWhenSignedIn).AsBoolean();
            pnlForm.Visible = (CurrentPersonId == null || displayForm);

            PopulatePersonIdentityFields(person, HasPersonActionIdentifier());


            ConfigurePhoneFieldForOccurrences(occurrenceIds, person);

            bool hasValidOccurrences = false;
            bool isExpired = false;

            using (var rockContext = new RockContext())
            {
                List<OccurrenceDataItem> repeaterItems = new List<OccurrenceDataItem>();
                var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);
                foreach (int occurrenceId in occurrenceIds)
                {
                    var occurrence = attendanceOccurrenceService.Get(occurrenceId);

                    // One stale id must not take down the occurrences alongside it. The loop
                    // already separates "skip this one" from "nothing here is valid", so if every
                    // id is unresolvable hasValidOccurrences stays false and the Show404 below fires.
                    if (occurrence == null || occurrence.Group == null)
                    {
                        continue;
                    }

                    var group = occurrence.Group;
                    var activeMembers = group.ActiveMembers().Count();
                    var acceptedRSVPs = occurrence.Attendees.Where(a => a.RSVP == Rock.Model.RSVP.Yes).Count();
                    var occClosedDate = occurrence.GetAttributeValue("ClosedDate").AsDateTime();
                    if (occClosedDate < RockDateTime.Now || acceptedRSVPs >= group.GroupCapacity)
                    {
                        // This event has expired.
                        isExpired = true;
                        continue;
                    }

                    // At least one occurrence is valid.
                    hasValidOccurrences = true;

                    var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                    if (groupMember == null)
                    {
                        //Person is not a member of the group associated with this invitation.
                        groupMember = new GroupMember();
                        groupMember.PersonId = person.Id;
                        groupMember.GroupId = occurrence.Group.Id;
                        groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                    }

                    groupMember.LoadAttributes();

                    // This collection object is created to limit attribute values to those marked "IsPublic".
                    var publicAttributes = new GroupMemberPublicAttriuteCollection(groupMember);

                    // Add item to collection for data binding.
                    repeaterItems.Add(
                        new OccurrenceDataItem()
                        {
                            Title = GetOccurrenceTitle(occurrence),
                            OccurrenceId = occurrenceId.ToString(),
                            PublicAttributes = publicAttributes
                        });
                }

                /// If no valid occurrences were found, display "Not Found" panel.
                if (!hasValidOccurrences)
                {
                    Show404(isExpired, GetAttributeValue(AttributeKey.MultigroupModeRSVPTitle));
                }
                else
                {
                    pnlMultiple_Choice.Visible = true;
                    MultipleOccurrenceDataItems = repeaterItems;
                    BindMultipleOccurrenceRepeater();
                }
            }
        }

        private void RebuildMultipleOccurrenceDataItems(List<int> occurrenceIds, Person person)
        {
            using (var rockContext = new RockContext())
            {
                List<OccurrenceDataItem> repeaterItems = new List<OccurrenceDataItem>();
                var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);


                foreach (int occurrenceId in occurrenceIds)
                {
                    var occurrence = attendanceOccurrenceService.Get(occurrenceId);

                    // Skip rather than fail, matching ShowMultipleOccurrence_Choice: one stale id in
                    // the list must not take down the valid occurrences beside it. Skipping still binds
                    // the repeater to whatever did resolve, so the page renders the rest normally.
                    if (occurrence == null || occurrence.Group == null || person == null)
                    {
                        continue;
                    }

                    var occClosedDate = occurrence.GetAttributeValue("ClosedDate").AsDateTime();
                    if (occClosedDate < RockDateTime.Now)
                    {
                        continue;
                    }

                    var groupMember = occurrence.Group.Members.Where(gm => gm.PersonId == person.Id).FirstOrDefault();
                    if (groupMember == null)
                    {
                        //Person is not a member of the group associated with this invitation.
                        groupMember = new GroupMember();
                        groupMember.PersonId = person.Id;
                        groupMember.GroupId = occurrence.Group.Id;
                        groupMember.GroupRoleId = occurrence.Group.GroupType.DefaultGroupRoleId ?? 0;
                    }

                    groupMember.LoadAttributes();

                    // This collection object is created to limit attribute values to those marked "IsPublic".
                    var publicAttributes = new GroupMemberPublicAttriuteCollection(groupMember);

                    // Add item to collection for data binding.
                    repeaterItems.Add(
                        new OccurrenceDataItem()
                        {
                            Title = GetOccurrenceTitle(occurrence),
                            OccurrenceId = occurrenceId.ToString(),
                            PublicAttributes = publicAttributes
                        });
                }

                MultipleOccurrenceDataItems = repeaterItems;
                BindMultipleOccurrenceRepeater();
            }
        }

        /// <summary>
        /// Binds the repeater control for multiple occurrences.
        /// </summary>
        private void BindMultipleOccurrenceRepeater()
        {
            rptrValues.DataSource = MultipleOccurrenceDataItems;
            rptrValues.DataBind();
        }

        /// <summary>
        /// Shows the RSVP Accept message for a single occurrence.
        /// </summary>
        /// <param name="occurrenceIds">The List of IDs of the AttendanceOccurrences.</param>
        /// <param name="person">The Person record of the respondent.</param>
        private void ShowMultipleOccurrence_Accept(List<int> occurrenceIds, Person person)
        {
            using (var rockContext = new RockContext())
            {
                _processedOccurrences = new List<string>();
                bool occurrenceProcessed = false;
                var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);

                foreach (RepeaterItem item in rptrValues.Items)
                {
                    if (ProcessOccurrence(person, item, rockContext))
                    {
                        occurrenceProcessed = true;
                    }
                }

                // If no occurrences were selected, do nothing.
                if (occurrenceProcessed)
                {
                    // Show Multiple Occurrence Accept message.
                    pnlMultiple_Accept.Visible = true;
                    pnlMultiple_Choice.Visible = false;
                    pnlForm.Visible = false;

                    var mergeFields = Rock.Lava.LavaHelper.GetCommonMergeFields(RockPage, CurrentPerson);
                    mergeFields.Add("AcceptedRsvps", _processedOccurrences);
                    nbAcceptMultiple.Text = GetAttributeValue(AttributeKey.MultigroupAcceptMessage).ResolveMergeFields(mergeFields);
                    nbNoOccurrencesSelected.Visible = false;
                }
                else
                {
                    nbNoOccurrencesSelected.Visible = true;
                }

                Authorization.SignOut();
            }
        }

        /// <summary>
        /// Stores a list of occurrences that were accepted, for inclusion in the Lava accept message.
        /// </summary>
        private List<string> _processedOccurrences;

        /// <summary>
        /// Processes a single RSVP Occurrence from data contained in a PanelWidget control.
        /// </summary>
        /// <param name="person">The Person record.</param>
        /// <param name="widget">The PanelWidget control.</param>
        /// <param name="rockContext">The RockContext.</param>
        /// <returns></returns>
        private bool ProcessOccurrence(Person person, RepeaterItem item, RockContext rockContext)
        {
            RockCheckBox rcbAccept = item.FindControl("rcbAccept") as RockCheckBox;

            // FindControl returns null if the repeater template changes or the cast fails, and this
            // runs once per repeater item, so an unchecked dereference took down the entire
            // multi-occurrence submit. Nothing was accepted if the checkbox is not there.
            if (rcbAccept == null || person == null)
            {
                return false;
            }

            if (rcbAccept.Checked)
            {
                HiddenField hfOccurrenceId = item.FindControl("hfOccurrenceId") as HiddenField;
                PlaceHolder phOccurrenceAttributes = item.FindControl("phOccurrenceAttributes") as PlaceHolder;

                // AsInteger rather than int.Parse: this value round-trips through a hidden field, so a
                // blank or tampered value threw FormatException instead of being handled. 0 never
                // resolves to an occurrence, so it falls into the guard below.
                int occurrenceId = hfOccurrenceId?.Value.AsInteger() ?? 0;
                var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);
                var occurrence = attendanceOccurrenceService.Get(occurrenceId);

                person = new PersonService(rockContext).Get(person.Guid);

                // UpdateOrCreateAttendanceRecord and GetOccurrenceTitle both dereference occurrence
                // unchecked. Report the item as not accepted rather than recording an RSVP against an
                // occurrence that no longer exists.
                if (occurrence == null || person == null)
                {
                    return false;
                }

                UpdateOrCreateAttendanceRecord(occurrence, person, rockContext, Rock.Model.RSVP.Yes, phOccurrenceAttributes);
                _processedOccurrences.Add(GetOccurrenceTitle(occurrence));
            }

            // The Authorization.SignOut() that used to sit below this return was unreachable, so it
            // never signed anyone out. Removed rather than hoisted above the return: making it
            // actually run would change behaviour, which is a separate decision from deleting code
            // that has never executed.
            return rcbAccept.Checked;
        }

        /// <summary>
        /// Updates the person record with name and email address fields.  This method is only called when NOT using a PersonActionIdentifier (i.e., the user must be logged in).
        /// </summary>
        private void UpdatePersonRecord(Person CurrentPerson)
        {
            using (var rockContext = new RockContext())
            {
                if (rtbFirstName.Text.IsNotNullOrWhiteSpace())
                {
                    CurrentPerson.FirstName = rtbFirstName.Text;
                }

                if (rtbLastName.Text.IsNotNullOrWhiteSpace())
                {
                    CurrentPerson.LastName = rtbLastName.Text;
                }

                if (rebEmail.Text.IsNotNullOrWhiteSpace())
                {
                    CurrentPerson.Email = rebEmail.Text;
                }



                if (!string.IsNullOrWhiteSpace(PhoneNumber.CleanNumber(pnbPhone.Number)))
                {
                    // Was a hardcoded 12. That is the Mobile DefinedValue's Id in this database, but
                    // Ids are not portable between databases, so resolve the well-known guid instead --
                    // same value here, without silently writing to the wrong phone type after a restore
                    // or a migration. The 12 is kept only as a last-resort fallback.
                    int phoneNumberTypeId = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.PERSON_PHONE_TYPE_MOBILE.AsGuid())?.Id ?? 12;

                    var phoneNumber = CurrentPerson.PhoneNumbers.FirstOrDefault(n => n.NumberTypeValueId == phoneNumberTypeId);
                    string oldPhoneNumber = string.Empty;
                    bool isNewPhoneNumber = phoneNumber == null;
                    if (isNewPhoneNumber)
                    {
                        phoneNumber = new PhoneNumber { NumberTypeValueId = phoneNumberTypeId };
                        CurrentPerson.PhoneNumbers.Add(phoneNumber);
                    }
                    else
                    {
                        oldPhoneNumber = phoneNumber.NumberFormattedWithCountryCode;
                    }

                    phoneNumber.CountryCode = PhoneNumber.CleanNumber(pnbPhone.CountryCode);
                    phoneNumber.Number = PhoneNumber.CleanNumber(pnbPhone.Number);

                    // This was set true unconditionally, which silently re-enabled SMS for anyone who
                    // had deliberately opted out -- and 76,163 of the 103,909 mobile numbers on file
                    // are opted out, so submitting an RSVP was overwriting a stored consent decision
                    // at scale. Only set it when adding a number that has no stored preference yet;
                    // never overwrite an existing one.
                    if (isNewPhoneNumber)
                    {
                        phoneNumber.IsMessagingEnabled = true;
                    }



                }
                // Saving Gender
                if (!string.IsNullOrWhiteSpace(rblGender.SelectedValue))
                {
                    CurrentPerson.Gender = rblGender.SelectedValue.ConvertToEnum<Gender>();
                }
                // Saving Marital Status
                if (!string.IsNullOrWhiteSpace(dvpMaritalStatus1.SelectedDefinedValueId.ToString()))
                {
                    CurrentPerson.MaritalStatusValueId = dvpMaritalStatus1.SelectedDefinedValueId;
                }
                // Saving Birth Date
                if (dpBirthDate1.SelectedDate.HasValue)
                {
                    CurrentPerson.SetBirthDate(dpBirthDate1.SelectedDate);
                }
                // Saving Address
                if (!string.IsNullOrWhiteSpace(acAddress.Street1) && !string.IsNullOrWhiteSpace(acAddress.City))
                {
                    var groupService = new GroupService(rockContext);
                    var familyGuid = CurrentPerson.GetFamily().Guid;
                    var primaryFamily = groupService.Get(familyGuid);
                    bool saveEmptyValues = primaryFamily != null;
                    var homeLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_HOME.AsGuid());
                    if (homeLocationType != null)
                    {
                        // Find a location record for the address that was entered
                        var loc = new Location();
                        acAddress.GetValues(loc);
                        if (acAddress.Street1.IsNotNullOrWhiteSpace() && loc.City.IsNotNullOrWhiteSpace())
                        {
                            loc = new LocationService(rockContext).Get(
                                loc.Street1, loc.Street2, loc.City, loc.State, loc.PostalCode, loc.Country, primaryFamily, true);
                        }
                        else
                        {
                            loc = null;
                        }

                        // Check to see if family has an existing home address
                        var groupLocation = primaryFamily.GroupLocations
                            .FirstOrDefault(l =>
                               l.GroupLocationTypeValueId.HasValue &&
                               l.GroupLocationTypeValueId.Value == homeLocationType.Id);

                        if (loc != null)
                        {
                            if (groupLocation == null || groupLocation.LocationId != loc.Id)
                            {
                                // If family does not currently have a home address or it is different than the one entered, add a new address (move old address to prev)
                                GroupService.AddNewGroupAddress(rockContext, primaryFamily, homeLocationType.Guid.ToString(), loc, true, string.Empty, true, true);
                            }
                        }
                        else
                        {
                            if (groupLocation != null && saveEmptyValues)
                            {
                                // If an address was not entered, and family has one on record, update it to be a previous address
                                var prevLocationType = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_PREVIOUS.AsGuid());
                                if (prevLocationType != null)
                                {
                                    groupLocation.GroupLocationTypeValueId = prevLocationType.Id;
                                }
                            }
                        }

                        //rockContext.SaveChanges();
                    }
                }

                rockContext.SaveChanges();
            }
        }

        /// <summary>
        /// Get Decline Reason DefinedValues for a list of IDs.
        /// </summary>
        /// <param name="commaDelimitedDeclineReasons">The IDs of the DevinedValues to retrieve.</param>
        /// <returns></returns>
        protected List<DefinedValue> GetDeclineReasons(string commaDelimitedDeclineReasons)
        {
            List<DefinedValue> values = new List<DefinedValue>();
            List<int> declineReasonIds = new List<int>();
            if (!string.IsNullOrWhiteSpace(commaDelimitedDeclineReasons))
            {
                declineReasonIds = commaDelimitedDeclineReasons.Split(',').Select(int.Parse).ToList();
            }

            if (!declineReasonIds.Any())
            {
                return values;
            }

            using (var rockContext = new RockContext())
            {
                var def = new DefinedValueService(rockContext);
                values = def.Queryable()
                    .Where(v => declineReasonIds.Contains(v.Id))
                    .AsNoTracking().ToList();
            }

            return values;
        }

        /// <summary>
        /// Sets the button style and text properties to match query string values passed in by the email editor.
        /// </summary>
        private void SetButtonProperties(int occurrenceId)
        {
            // Set Group from OccurrenceId

            using (var rockContext = new RockContext())
            {
                var attendanceOccurrenceService = new AttendanceOccurrenceService(rockContext);
                var occurrence = attendanceOccurrenceService.Get(occurrenceId);

                // A bare "/RSVP" visit, an empty AttendanceOccurrenceId, or a stale link from an old
                // email all arrive here with nothing to look up, and dereferencing the missing
                // occurrence threw a NullReferenceException out of OnInit -- which took down the whole
                // page instead of letting the block render its own "could not be found" notification.
                // This method only reads group attributes to style the Accept/Decline buttons, so when
                // there is no occurrence the correct behaviour is to leave those defaults alone.
                if (occurrence == null || occurrence.Group == null)
                {
                    return;
                }

                var group = occurrence.Group;
                group.LoadAttributes();


                // sets the art/button styles either from the page parameter or from the group attribute.
                // Example of a cleaner, easier-to-read approach:
                string parameterAcceptText = PageParameter(PageParameterKey.AcceptButtonText);
                string acceptButtonText = !string.IsNullOrEmpty(parameterAcceptText) ? parameterAcceptText : group.GetAttributeValue("Art_AcceptButtonText");
                string parameterAcceptColor = PageParameter(PageParameterKey.AcceptButtonColor);
                string acceptButtonColor = !string.IsNullOrEmpty(parameterAcceptColor) ? parameterAcceptColor : group.GetAttributeValue("Art_AcceptButtonColor");
                string parameterAcceptFont = PageParameter(PageParameterKey.AcceptButtonFontColor);
                string acceptButtonFontColor = !string.IsNullOrEmpty(parameterAcceptFont) ? parameterAcceptFont : group.GetAttributeValue("Art_AcceptFontColor");
                string parameterDeclineText = PageParameter(PageParameterKey.DeclineButtonText);
                string declineButtonText = !string.IsNullOrEmpty(parameterDeclineText) ? parameterDeclineText : group.GetAttributeValue("Art_DeclineButtonText");
                string parameterDeclineButton = PageParameter(PageParameterKey.DeclineButtonColor);
                string declineButtonColor = !string.IsNullOrEmpty(parameterDeclineButton) ? parameterDeclineButton : group.GetAttributeValue("Art_DeclineButtonColor");
                string parameterDeclineFont = PageParameter(PageParameterKey.DeclineButtonFontColor);
                string declineButtonFontColor = !string.IsNullOrEmpty(parameterDeclineFont) ? parameterDeclineFont : group.GetAttributeValue("Art_DeclineFontColor");
                string includeDecline = PageParameter(PageParameterKey.IncludeDecline);
                /*
                string acceptButtonText = PageParameter(PageParameterKey.AcceptButtonText);
                string acceptButtonColor = PageParameter(PageParameterKey.AcceptButtonColor);
                string acceptButtonFontColor = PageParameter(PageParameterKey.AcceptButtonFontColor);
                string declineButtonText = PageParameter(PageParameterKey.DeclineButtonText);
                string declineButtonColor = PageParameter(PageParameterKey.DeclineButtonColor);
                string declineButtonFontColor = PageParameter(PageParameterKey.DeclineButtonFontColor);
                string includeDecline = PageParameter(PageParameterKey.IncludeDecline);
                */

                if (!string.IsNullOrWhiteSpace(acceptButtonText))
                {
                    lbAccept_Multiple.Text = acceptButtonText;
                    lbAccept_Single.Text = acceptButtonText;
                }

                if (!string.IsNullOrWhiteSpace(declineButtonText))
                {
                    lbDecline_Single.Text = declineButtonText;
                }

                string acceptButtonStyle = string.Empty;
                if (!string.IsNullOrWhiteSpace(acceptButtonColor))
                {
                    acceptButtonStyle = "background-color: " + acceptButtonColor + ";";
                }
                if (!string.IsNullOrWhiteSpace(acceptButtonFontColor))
                {
                    acceptButtonStyle = acceptButtonStyle + "color: " + acceptButtonFontColor + ";";
                }
                if (!string.IsNullOrWhiteSpace(acceptButtonStyle))
                {
                    lbAccept_Multiple.CssClass = "btn";
                    lbAccept_Multiple.Attributes.Remove("style");
                    lbAccept_Multiple.Attributes.Add("style", acceptButtonStyle);
                    lbAccept_Single.CssClass = "btn form-group";
                    lbAccept_Single.Attributes.Remove("style");
                    lbAccept_Single.Attributes.Add("style", acceptButtonStyle);
                }
                else
                {
                    lbAccept_Multiple.CssClass = "btn btn-primary";
                    lbAccept_Single.CssClass = "btn btn-primary";
                }


                string declineButtonStyle = string.Empty;
                if (!string.IsNullOrWhiteSpace(declineButtonColor))
                {
                    declineButtonStyle = "background-color: " + declineButtonColor + ";";
                }
                if (!string.IsNullOrWhiteSpace(declineButtonFontColor))
                {
                    declineButtonStyle = declineButtonStyle + "color: " + declineButtonFontColor + ";";
                }
                if (!string.IsNullOrWhiteSpace(declineButtonStyle))
                {
                    lbDecline_Single.CssClass = "btn";
                    lbDecline_Single.Attributes.Remove("style");
                    lbDecline_Single.Attributes.Add("style", declineButtonStyle);
                }
                else
                {
                    lbDecline_Single.CssClass = "btn btn-default";
                }

                if (includeDecline == "false")
                {
                    lbDecline_Single.Visible = false;
                }
            }
        }

        #endregion

        protected void rptrValues_ItemDataBound(object sender, RepeaterItemEventArgs e)
        {
            var dataItem = e.Item.DataItem as OccurrenceDataItem;
            var phOccurrenceAttributes = e.Item.FindControl("phOccurrenceAttributes");
            if (dataItem.PublicAttributes.Attributes.Any())
            {
                Helper.AddEditControls(dataItem.PublicAttributes, phOccurrenceAttributes, !Page.IsPostBack);
            }
        }
    }

    #region Helper Classes
    /// <summary>
    /// This class is used to obtain a list of attributes which are marked IsPublic.
    /// </summary>
    public class GroupMemberPublicAttriuteCollection : IHasAttributes
    {

        /// <summary>
        /// Gets the id.
        /// </summary>
        public int Id { get; set; }

        /// <summary>
        /// List of attributes associated with the object.  This property will not include the attribute values.
        /// The <see cref="AttributeValues" /> property should be used to get attribute values.  Dictionary key
        /// is the attribute key, and value is the cached attribute
        /// </summary>
        /// <value>
        /// The attributes.
        /// </value>
        public Dictionary<string, AttributeCache> Attributes { get; set; }

        /// <summary>
        /// Dictionary of all attributes and their value.  Key is the attribute key, and value is the associated attribute value
        /// </summary>
        /// <value>
        /// The attribute values.
        /// </value>
        public Dictionary<string, AttributeValueCache> AttributeValues { get; set; }

        /// <summary>
        /// Gets the attribute value defaults.  This property can be used by a subclass to override the parent class's default
        /// value for an attribute
        /// </summary>
        /// <value>
        /// The attribute value defaults.
        /// </value>
        public Dictionary<string, string> AttributeValueDefaults
        {
            get { return null; }
        }

        /// <summary>
        /// Gets the value of an attribute key.
        /// </summary>
        /// <param name="key">The key.</param>
        /// <returns></returns>
        public string GetAttributeValue(string key)
        {
            if (this.AttributeValues != null &&
                this.AttributeValues.ContainsKey(key))
            {
                return this.AttributeValues[key].Value;
            }

            if (this.Attributes != null &&
                this.Attributes.ContainsKey(key))
            {
                return this.Attributes[key].DefaultValue;
            }

            return null;
        }

        /// <summary>
        /// Gets the value of an attribute key - splitting that delimited value into a list of strings.
        /// </summary>
        /// <param name="key">The key.</param>
        /// <returns>
        /// A list of string values or an empty list if none exist.
        /// </returns>
        public List<string> GetAttributeValues(string key)
        {
            string value = GetAttributeValue(key);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value.SplitDelimitedValues().ToList();
            }

            return new List<string>();
        }

        /// <summary>
        /// Takes the broken URL from a structured content field and puts an absolute URL, which is a parameter
        /// </summary>
        /// <param url="URL">The key.</param>
        /// <returns>
        /// The structured content JSON payload with the updated URL field for images
        /// </returns>
        /* public string ReplaceUrl(string content, string url)
        {
            string new_content = content.Replace("/GetImage.ashx?", url);

            return new_content;
        }
        */
        /// <summary>
        /// Sets the value of an attribute key in memory.  Note, this will not persist value to database
        /// </summary>
        /// <param name="key">The key.</param>
        /// <param name="value">The value.</param>
        public void SetAttributeValue(string key, string value)
        {
            if (this.AttributeValues != null &&
                this.AttributeValues.ContainsKey(key))
            {
                this.AttributeValues[key].Value = value;
            }
        }

        /// <summary>
        /// Initializes a new instance of the <see cref="GroupMemberPublicAttriuteCollection"/> class.
        /// </summary>
        public GroupMemberPublicAttriuteCollection(GroupMember groupMember)
        {
            Id = groupMember.Id;
            groupMember.LoadAttributes();
            Attributes = groupMember.Attributes.Where(a => a.Value.IsPublic == true).ToDictionary(a => a.Key, a => a.Value);
            AttributeValues = groupMember.AttributeValues.Where(a => Attributes.Keys.Contains(a.Value.AttributeKey)).ToDictionary(a => a.Key, a => a.Value);
        }

        public GroupMemberPublicAttriuteCollection() { }
    }

    public static class DateEndOfDayStaticFunction
    {
        public static DateTime EndOfDay(this DateTime input)
        {
            return input.Date.AddDays(1).AddMilliseconds(-1);
        }
    }

        #endregion
    }