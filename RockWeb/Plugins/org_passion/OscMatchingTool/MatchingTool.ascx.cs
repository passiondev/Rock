
using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Web;
using System.Web.UI;
using System.Web.UI.WebControls;

using Rock;
using Rock.Data;
using Rock.Blocks;
using Rock.Model;
using Rock.Web.Cache;
using Rock.Web.UI.Controls;
using Rock.Attribute;
using System.Collections.Generic;

class ProjectPreferences
{
    public string id { get; set; }
    public string name { get; set; }
    public string partner { get; set; }
    public int time_period { get; set; }
    public int day { get; set; }
    public int campus { get; set; }
    public string osc_selected { get; set; }
}
class PersonPreferences
{
    public string id { get; set; }
    public List<int> time_prefs { get; set; }
    public List<int> day_prefs { get; set; }
    public int campus { get; set; }
    public int gender { get; set; }
    public int max_projects { get; set; }
}

class DetractScores
{
    const int campus = -5;
    const int day = -5;
    const int time = -5;
    const int selection = -5;
}

class AffirmScores
{
    const int campus = 20;
    const int day = 10;
    const int time = 5;
    const int selection = 5;
}

namespace RockWeb.Plugins.org_passion.OscMatchingTool
{


    [DisplayName("Matching Tool")]
    [Category("PCC > OSC Matching")]
    [Description("Initial block for OSC matching tool")]

    #region Block Attributes

    [BooleanField(
        "Show Email Address",
        Key = AttributeKey.ShowEmailAddress,
        Description = "Should the email address be shown?",
        DefaultBooleanValue = true,
        Order = 1)]

    [EmailField(
        "Email",
        Key = AttributeKey.Email,
        Description = "The Email address to show.",
        DefaultValue = "ted@rocksolidchurchdemo.com",
        Order = 2)]

    [CustomRadioListField("Gender Filter", "Select in order to list only records for that gender", "1^Male,2^Female", required: false)]

    #endregion Block Attributes

    public partial class MatchingTool : Rock.Blocks.RockObsidianBlockType
    {

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
            // List<ProjectPreferences> projects = new List<ProjectPreferences>();
            // List<PersonPreferences> people = new List<PersonPreferences>();

            // CalculateScore(projects, people);
        }
        protected void BindGrid()
        {
            var genderValue = GetAttributeValue("GenderFilter");

            var query = new PersonService(new RockContext()).Queryable();

            if (!string.IsNullOrEmpty(genderValue))
            {
                Gender gender = genderValue.ConvertToEnum<Gender>();
                query = query.Where(p => p.Gender == gender);
            }

            gPeople.DataSource = query.ToList();
            gPeople.DataBind();
        }
        void CalculateScore(List<ProjectPreferences> projects, List<PersonPreferences> people)
        {

        }

        #region Attribute Keys

        private static class AttributeKey
        {
            public const string ShowEmailAddress = "ShowEmailAddress";
            public const string Email = "Email";
        }

        #endregion Attribute Keys

        #region PageParameterKeys

        private static class PageParameterKey
        {
            public const string StarkId = "StarkId";
        }

        #endregion PageParameterKeys

        #region Fields

        // Used for private variables.

        #endregion

        #region Properties

        // Used for public / protected properties.

        #endregion

        #region Base Control Methods

        // Overrides of the base RockBlock methods (i.e. OnInit, OnLoad)

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);

            // This event gets fired after block settings are updated. It's nice to repaint the screen if these settings would alter it.
            this.BlockUpdated += Block_BlockUpdated;
            this.AddConfigurationUpdateTrigger(upnlContent);
        }

        #endregion

        #region Events

        // Handlers called by the controls on your block.

        /// <summary>
        /// Handles the BlockUpdated event of the control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void Block_BlockUpdated(object sender, EventArgs e)
        {
            BindGrid();
        }

        #endregion

        #region Methods
        public override object GetObsidianBlockInitialization()
        {

        }

        // helper functional methods (like BindGrid(), etc.)

        #endregion
    }
}