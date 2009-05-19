# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

class ApplicationController < ActionController::Base

  before_filter :remove_trailing_slash

  before_filter :user_login_flash
  after_filter :user_login_flash

  include CacheableFlash
  before_filter :write_flash_to_cookie

  # prevent any field that matches /password/ from being logged
  filter_parameter_logging "password"

  caches_action :home, :about, :contact, :parliament

  layout "application"

  def is_parlywords_request?
    request.host == 'parlywords.org.nz'
  end

  def show_single_date
    if is_parlywords_request?
      @date = params[:date]
      the_date = Date.parse(@date)

      if SittingDay.has_parlywords? the_date
        @date_label = the_date.to_s(:rfc822).strip
        render :template => 'parlywords_on_date', :layout => 'parlywords'
      else
        render(:text => 'no parly words on date', :status => 404)
      end
    end
  end

  def newspaper
    @latest_debates = Debate.find_latest_by_status('A')
    render :template => 'newspaper', :layout => false
  end

  def home
    if is_parlywords_request?
      # render :template => 'parlywords', :layout => 'parlywords'
      render :text => 'coming soon', :layout => false
    else
      begin
        @weeks_top_pages = top_content 7
        @days_top_pages = top_content 1
      rescue Exception => e
        logger.error e
        @weeks_top_pages = nil
        @days_top_pages = nil
      end

      @latest_debates = Debate.find_latest_by_status('A')
      @latest_orals = Debate.find_latest_by_status('U')

      @third_reading_matrix = Vote.third_reading_matrix
      @submission_dates = SubmissionDate.find_live_bill_submissions
      render :template => 'home'
    end
  end

  def parliament
    if params[:id] == '48'
      @third_reading_matrix = Vote.third_reading_matrix
      render :template => 'parliaments/48'
    else
      render(:text => 'not found', :status => 404)
    end
  end

  def about
    render :template => 'about'
  end

  def contact
    render :template => 'contact'
  end

  def search
    @term = params[:q]
    render :template => 'debates/search' and return if @term == nil

    page = params['page'] || 1
    @entries = WillPaginate::Collection.create(page, 10) do |pager|
      @matches, @count = Contribution.match_by_term(@term, pager.per_page, pager.offset)
      pager.replace(@matches)
      pager.total_entries = @count
    end

    unless @matches.empty?
      @matches = @matches.compact
      @debate_ids = @matches.collect {|m| m.spoken_in_id}.uniq
      @by_debate = @matches.group_by {|m| m.spoken_in_id}

      debates = []
      @debate_ids.each_with_index {|id,i| debates[i] = Debate.find(id)}

      debates = Debate::remove_duplicates debates
      debates.sort! { |a,b| b.date <=> a.date }

      @debate_ids = debates.collect { |d| d.id }

      @debates = {}
      @debate_ids.each_with_index {|id,i| @debates[id] = debates[i]}

      render :template => 'debates/search'
    else
      flash[:term] = @term
      render :template => 'debates/search_form'
    end
  end

  def logged_in
    if current_user
      true
    else
      flash[:warning] = 'Please login to continue'
      session[:return_to] = request.request_uri
      redirect_to :controller => "user", :action => "login"
      false
    end
  end

  def current_user
    session[:user]
  end

  def redirect_to_stored
    if return_to = session[:return_to]
      session[:return_to] = nil
      redirect_to return_to
    else
      redirect_to :controller => 'user', :action => 'user_home', :user_name => current_user.login
    end
  end

  def flash_js
    render(:file=> 'javascript/flash.js' )
  end

  def admin?
    current_user && current_user.login == 'rob'
  end

  private

    def top_content days
      profile = Rugalytics.default_profile
      previous_date = Date.today - days
      report = profile.top_content_report :from => previous_date
      items = report.items.delete_if{|i| (i.path[/\d\d\d\d/].nil? && !i.path[/bills\//]) || i.path[/search\?/] || i.path[/portfolios\/education\/2007\/jul\/\d\d\/teachers/] }
      # items = items.sort_by{|i| i.unique_pageviews.to_i}.reverse
      items = items.collect do |item|
        item.path.sub!('mori','maori')
        item.url.sub!('mori','maori')
        UrlItem.new(item)
      end
      items = items.sort_by{|i| i.weighted_score }.reverse
      items = items[0..9] if items.size > 10
      items
    end

    def site_url
      host = request.host_with_port.include?('80') ? request.host : request.host_with_port
      request.protocol + host
    end

    def user_login_flash
      site = site_url
      if current_user
        user_url = site + '/user/' + current_user.login
        logout_url = site + '/users/logout'

        flash[:login_form] = ' '
        flash[:logged_in] = '' +
            %Q[<span>Welcome, <a href="#{user_url}">#{current_user.login}</a></span> | ] +
            %Q[<span><a href="#{logout_url}">Sign out</a></span>]
      else
        sign_up_url = site + '/users/signup'
        login_url = site + '/users/login'
        log_in_links = '' +
            %Q[<span><a title="User sign up" href="#{sign_up_url}">Sign up</a></span> or ] +
            %Q[<span><a title="User login" href="#{login_url}">login</a></span>]
        # flash[:logged_in] = log_in_links
        flash[:logged_in] = ' '
      end
    end

    def remove_trailing_slash
      uri = request.request_uri
      if uri.length > 1 and uri[-1,1] == '/'
        uri = request.protocol + request.host + uri.chop
        redirect_to uri,
        headers['Status'] = '301 Moved Permanently'
      end
    end

    def marker geoname, debates
      debate_links = debates.collect { |debate| render_to_string(:partial => 'debates/map_debate_link', :object => debate) }

      GMarker.new([geoname.latitude,geoname.longitude],
          :title => geoname.name,
          :info_window =>
              '<strong>' + geoname.name + '</strong><ul>' +
              debate_links.join('')+'</ul>'
          )
    end

    def make_map geonames_to_debates, lat, long, zoom=6
      if RAILS_ENV == 'test' || RAILS_ENV == 'development' || RAILS_ENV == 'production'
        return nil
      end
      map = GMap.new("map_div")
      if map
        map.control_init(:large_map => true,:map_type => true)
        map.center_zoom_init([lat, long], zoom)
        geonames_to_debates.each do |geoname, debates|
          map.record_init map.add_overlay(marker(geoname, debates))
        end
      end
      map
    end

    def geonames_to_debates debates
      debate_geonames = debates.collect{ |d| [d, d.geonames] }
      names_to_debates = {}

      debate_geonames.each do |item|
        debate = item[0]
        geonames = item[1]

        geonames.each do |geoname|
          names_to_debates[geoname] = [] unless names_to_debates.has_key?(geoname)
          names_to_debates[geoname] << debate
        end
      end

      names_to_debates
    end
end
