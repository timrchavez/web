port module Dashboard exposing (Model, Msg, init, update, subscriptions, view, filterBy, searchTermList, pipelineStatus, lastPipelineStatus, StatusPipeline)

import BuildDuration
import Concourse
import Concourse.Cli
import Concourse.Info
import Concourse.Job
import Concourse.Pipeline
import Concourse.PipelineStatus
import DashboardPreview
import Date exposing (Date)
import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes exposing (class, classList, id, href, src, attribute)
import Html.Attributes.Aria exposing (ariaLabel)
import Http
import Keyboard
import Mouse
import Dom
import Char
import NewTopBar
import RemoteData
import Task exposing (Task)
import Time exposing (Time)
import Simple.Fuzzy exposing (match, root, filter)
import BetaRoutes


port pinTeamNames : () -> Cmd msg


type alias Model =
    { topBar : NewTopBar.Model
    , pipelines : RemoteData.WebData (List Concourse.Pipeline)
    , jobs : Dict Int (RemoteData.WebData (List Concourse.Job))
    , concourseVersion : String
    , turbulenceImgSrc : String
    , now : Maybe Time
    , showHelp : Bool
    , hideFooter : Bool
    , hideFooterCounter : Time
    , fetchedPipelines : List Concourse.Pipeline
    }


type Msg
    = Noop
    | PipelinesResponse (RemoteData.WebData (List Concourse.Pipeline))
    | JobsResponse Int (RemoteData.WebData (List Concourse.Job))
    | ClockTick Time.Time
    | VersionFetched (Result Http.Error String)
    | AutoRefresh Time
    | ShowFooter
    | KeyPressed Keyboard.KeyCode
    | TopBarMsg NewTopBar.Msg


type alias PipelineWithJobs =
    { pipeline : Concourse.Pipeline
    , jobs : RemoteData.WebData (List Concourse.Job)
    }


type alias StatusPipeline =
    { pipeline : Concourse.Pipeline
    , status : String
    }


type alias JobBuilds j =
    { j
        | nextBuild : Maybe Concourse.Build
        , finishedBuild : Maybe Concourse.Build
        , paused : Bool
    }


init : String -> ( Model, Cmd Msg )
init turbulencePath =
    let
        ( topBar, topBarMsg ) =
            NewTopBar.init
    in
        ( { topBar = topBar
          , pipelines = RemoteData.NotAsked
          , jobs = Dict.empty
          , now = Nothing
          , turbulenceImgSrc = turbulencePath
          , concourseVersion = ""
          , showHelp = False
          , hideFooter = False
          , hideFooterCounter = 0
          , fetchedPipelines = []
          }
        , Cmd.batch
            [ fetchPipelines
            , fetchVersion
            , getCurrentTime
            , Cmd.map TopBarMsg topBarMsg
            , pinTeamNames ()
            ]
        )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Noop ->
            ( model, Cmd.none )

        PipelinesResponse response ->
            ( { model | pipelines = response }
            , case response of
                RemoteData.Success pipelines ->
                    Cmd.batch (List.map fetchJobs pipelines)

                _ ->
                    Cmd.none
            )

        JobsResponse pipelineId response ->
            ( { model | jobs = Dict.insert pipelineId response model.jobs }, Cmd.none )

        VersionFetched (Ok version) ->
            ( { model | concourseVersion = version }, Cmd.none )

        VersionFetched (Err err) ->
            flip always (Debug.log ("failed to fetch version") (err)) <|
                ( { model | concourseVersion = "" }, Cmd.none )

        ClockTick now ->
            if model.hideFooterCounter + Time.second > 5 * Time.second then
                ( { model | now = Just now, hideFooter = True }, Cmd.none )
            else
                ( { model | now = Just now, hideFooterCounter = model.hideFooterCounter + Time.second }, Cmd.none )

        AutoRefresh _ ->
            ( model, Cmd.batch [ fetchPipelines, fetchVersion, Cmd.map TopBarMsg NewTopBar.fetchUser ] )

        KeyPressed keycode ->
            handleKeyPressed (Char.fromCode keycode) model

        ShowFooter ->
            ( { model | hideFooter = False, hideFooterCounter = 0 }, Cmd.none )

        TopBarMsg msg ->
            let
                ( newTopBar, newTopBarMsg ) =
                    NewTopBar.update msg model.topBar

                newModel =
                    case msg of
                        NewTopBar.FilterMsg query ->
                            { model
                                | topBar = newTopBar
                                , fetchedPipelines = filterModelPipelines query model
                            }

                        NewTopBar.UserFetched _ ->
                            { model | topBar = newTopBar }
            in
                ( newModel, Cmd.map TopBarMsg newTopBarMsg )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every Time.second ClockTick
        , Time.every (5 * Time.second) AutoRefresh
        , Mouse.moves (\_ -> ShowFooter)
        , Mouse.clicks (\_ -> ShowFooter)
        , Keyboard.presses KeyPressed
        ]


view : Model -> Html Msg
view model =
    Html.div [ class "page" ]
        [ Html.map TopBarMsg (NewTopBar.view model.topBar)
        , viewDashboard model
        ]


viewDashboard : Model -> Html Msg
viewDashboard model =
    let
        listFetchedPipelinesLength =
            List.length model.fetchedPipelines

        isQueryEmpty =
            String.isEmpty model.topBar.query
    in
        case model.pipelines of
            RemoteData.Success pipelines ->
                if listFetchedPipelinesLength > 0 then
                    showPipelinesView model model.fetchedPipelines
                else if not isQueryEmpty then
                    showNoResultsView (toString model.topBar.query)
                else
                    showPipelinesView model pipelines

            RemoteData.Failure _ ->
                showTurbulenceView model

            _ ->
                Html.text ""


showNoResultsView : String -> Html Msg
showNoResultsView query =
    let
        boldedQuery =
            Html.span [ class "monospace-bold" ] [ Html.text query ]
    in
        Html.div
            [ class "dashboard" ]
            [ Html.div [ class "dashboard-content " ]
                [ Html.div
                    [ class "dashboard-team-group" ]
                    [ Html.div [ class "pin-wrapper" ]
                        [ Html.div [ class "dashboard-team-name no-results" ]
                            [ Html.text "No results for "
                            , boldedQuery
                            , Html.text " matched your search."
                            ]
                        ]
                    ]
                ]
            ]


showPipelinesView : Model -> List Concourse.Pipeline -> Html Msg
showPipelinesView model pipelines =
    let
        pipelineStates =
            getPipelineStates model pipelines

        pipelinesByTeam =
            List.foldl
                (\pipelineState byTeam ->
                    addPipelineState byTeam ( pipelineState.pipeline.teamName, pipelineState )
                )
                []
                pipelineStates

        listPipelinesByTeam =
            List.map (\( teamName, pipelineStates ) -> viewGroup model.now teamName (List.reverse pipelineStates)) pipelinesByTeam
    in
        Html.div
            [ class "dashboard" ]
        <|
            [ Html.div [ class "dashboard-content" ] <| listPipelinesByTeam
            , showFooterView model
            , helpView model
            ]


helpView : Model -> Html Msg
helpView model =
    Html.div
        [ classList
            [ ( "keyboard-help", True )
            , ( "hidden", not model.showHelp )
            ]
        ]
        [ Html.div [ class "help-title" ] [ Html.text "keyboard shortcuts" ]
        , Html.div [ class "help-line" ] [ Html.div [ class "keys" ] [ Html.span [ class "key" ] [ Html.text "/" ] ], Html.text "search" ]
        , Html.div [ class "help-line" ] [ Html.div [ class "keys" ] [ Html.span [ class "key" ] [ Html.text "?" ] ], Html.text "hide/show help" ]
        ]


showFooterView : Model -> Html Msg
showFooterView model =
    Html.div
        [ if model.hideFooter || model.showHelp then
            class "dashboard-footer hidden"
          else
            class "dashboard-footer"
        ]
        [ Html.div [ class "dashboard-legend" ]
            [ Html.div [ class "dashboard-status-pending" ]
                [ Html.div [ class "dashboard-pipeline-icon" ] [], Html.text "pending" ]
            , Html.div [ class "dashboard-paused" ]
                [ Html.div [ class "dashboard-pipeline-icon" ] [], Html.text "paused" ]
            , Html.div [ class "dashboard-running" ]
                [ Html.div [ class "dashboard-pipeline-icon" ] [], Html.text "running" ]
            , Html.div [ class "dashboard-status-failed" ]
                [ Html.div [ class "dashboard-pipeline-icon" ] [], Html.text "failing" ]
            , Html.div [ class "dashboard-status-errored" ]
                [ Html.div [ class "dashboard-pipeline-icon" ] [], Html.text "errored" ]
            , Html.div [ class "dashboard-status-aborted" ]
                [ Html.div [ class "dashboard-pipeline-icon" ] [], Html.text "aborted" ]
            , Html.div [ class "dashboard-status-succeeded" ]
                [ Html.div [ class "dashboard-pipeline-icon" ] [], Html.text "succeeded" ]
            ]
        , Html.div [ class "concourse-version" ]
            [ Html.text "version: v", Html.text model.concourseVersion ]
        , Html.div [ class "concourse-cli" ]
            [ Html.text "cli: "
            , Html.a [ href (Concourse.Cli.downloadUrl "amd64" "darwin"), ariaLabel "Download OS X CLI" ]
                [ Html.i [ class "fa fa-apple" ] [] ]
            , Html.a [ href (Concourse.Cli.downloadUrl "amd64" "windows"), ariaLabel "Download Windows CLI" ]
                [ Html.i [ class "fa fa-windows" ] [] ]
            , Html.a [ href (Concourse.Cli.downloadUrl "amd64" "linux"), ariaLabel "Download Linux CLI" ]
                [ Html.i [ class "fa fa-linux" ] [] ]
            ]
        ]


showTurbulenceView : Model -> Html Msg
showTurbulenceView model =
    Html.div
        [ class "error-message" ]
        [ Html.div [ class "message" ]
            [ Html.img [ src model.turbulenceImgSrc, class "seatbelt" ] []
            , Html.p [] [ Html.text "experiencing turbulence" ]
            , Html.p [ class "explanation" ] []
            ]
        ]


handleKeyPressed : Char -> Model -> ( Model, Cmd Msg )
handleKeyPressed key model =
    case key of
        '/' ->
            ( model, Task.attempt (always Noop) (Dom.focus "search-input-field") )

        '?' ->
            ( { model | showHelp = not model.showHelp }, Cmd.none )

        _ ->
            update ShowFooter model


addPipelineState : List ( String, List PipelineWithJobs ) -> ( String, PipelineWithJobs ) -> List ( String, List PipelineWithJobs )
addPipelineState pipelineStates ( teamName, pipelineState ) =
    case pipelineStates of
        [] ->
            [ ( teamName, [ pipelineState ] ) ]

        s :: ss ->
            if Tuple.first s == teamName then
                ( teamName, pipelineState :: (Tuple.second s) ) :: ss
            else
                s :: (addPipelineState ss ( teamName, pipelineState ))


viewGroup : Maybe Time -> String -> List PipelineWithJobs -> Html msg
viewGroup now teamName pipelines =
    Html.div [ id teamName, class "dashboard-team-group", attribute "data-team-name" teamName ]
        [ Html.div [ class "pin-wrapper" ]
            [ Html.div [ class "dashboard-team-name" ] [ Html.text teamName ] ]
        , Html.div [ class "dashboard-team-pipelines" ]
            (List.map (viewPipeline now) pipelines)
        ]


viewPipeline : Maybe Time -> PipelineWithJobs -> Html msg
viewPipeline now state =
    let
        pStatus =
            pipelineStatus state

        lStatus =
            lastPipelineStatus state

        mJobs =
            case state.jobs of
                RemoteData.Success js ->
                    Just js

                _ ->
                    Nothing

        mpreview =
            Maybe.map DashboardPreview.view mJobs
    in
        Html.div
            [ classList
                [ ( "dashboard-pipeline", True )
                , ( "dashboard-paused", state.pipeline.paused )
                , ( "dashboard-running", isPipelineRunning pStatus || hasJobsRunning state.jobs )
                , ( setPipelineStatusClass lStatus, not state.pipeline.paused )
                ]
            , attribute "data-pipeline-name" state.pipeline.name
            ]
            [ Html.div [ class "dashboard-pipeline-banner" ] []
            , Html.div
                [ class "dashboard-pipeline-content" ]
                [ Html.a [ href <| BetaRoutes.pipelineRoute state.pipeline ]
                    [ Html.div
                        [ class "dashboard-pipeline-header" ]
                        [ Html.div [ class "dashboard-pipeline-name" ]
                            [ Html.text state.pipeline.name ]
                        ]
                    ]
                , case mpreview of
                    Just preview ->
                        preview

                    Nothing ->
                        Html.text ""
                , Html.div [ class "dashboard-pipeline-footer" ]
                    [ Html.div [ class "dashboard-pipeline-icon" ]
                        []
                    , timeSincePipelineTransitioned now state
                    ]
                ]
            ]


setPipelineStatusClass : Concourse.PipelineStatus -> String
setPipelineStatusClass status =
    if isPipelineRunning status then
        ""
    else
        "dashboard-status-" ++ Concourse.PipelineStatus.show status


timeSincePipelineTransitioned : Maybe Time -> PipelineWithJobs -> Html a
timeSincePipelineTransitioned time state =
    case state.jobs of
        RemoteData.Success js ->
            let
                status =
                    pipelineStatus state

                transitionedJobs =
                    List.filter
                        (\job ->
                            not <| xor (status == Concourse.PipelineStatusSucceeded) (Just (Concourse.BuildStatusSucceeded) == (Maybe.map .status job.finishedBuild))
                        )
                        js

                transitionedDurations =
                    List.filterMap
                        (\job ->
                            Maybe.map .duration job.transitionBuild
                        )
                        transitionedJobs

                sortedTransitionedDurations =
                    List.sortBy
                        (\duration ->
                            case duration.startedAt of
                                Just date ->
                                    Time.inSeconds <| Date.toTime date

                                Nothing ->
                                    0
                        )
                        transitionedDurations

                transitionedDuration =
                    if status == Concourse.PipelineStatusSucceeded then
                        List.head << List.reverse <| sortedTransitionedDurations
                    else
                        List.head <| sortedTransitionedDurations
            in
                case status of
                    Concourse.PipelineStatusPaused ->
                        Html.div [ class "build-duration" ] [ Html.text "paused" ]

                    Concourse.PipelineStatusPending ->
                        Html.div [ class "build-duration" ] [ Html.text "pending" ]

                    Concourse.PipelineStatusRunning ->
                        Html.div [ class "build-duration" ] [ Html.text "running" ]

                    _ ->
                        case ( time, transitionedDuration ) of
                            ( Just now, Just duration ) ->
                                BuildDuration.show duration now

                            _ ->
                                Html.text ""

        _ ->
            Html.text ""


isPipelineRunning : Concourse.PipelineStatus -> Bool
isPipelineRunning status =
    case status of
        Concourse.PipelineStatusRunning ->
            True

        _ ->
            False


isPipelineJobsRunning : PipelineWithJobs -> Bool
isPipelineJobsRunning { jobs } =
    case jobs of
        RemoteData.Success js ->
            List.any (\job -> job.nextBuild /= Nothing) js

        _ ->
            False


hasJobsRunning : RemoteData.WebData (List Concourse.Job) -> Bool
hasJobsRunning jobs =
    case jobs of
        RemoteData.Success js ->
            List.any (\job -> job.nextBuild /= Nothing) js

        _ ->
            False


pipelineStatus : { record | pipeline : { p | paused : Bool }, jobs : RemoteData.WebData (List (JobBuilds j)) } -> Concourse.PipelineStatus
pipelineStatus { pipeline, jobs } =
    if pipeline.paused == True then
        Concourse.PipelineStatusPaused
    else
        case jobs of
            RemoteData.Success js ->
                pipelineStatusFromJobs js

            _ ->
                Concourse.PipelineStatusPending


lastPipelineStatus : { record | pipeline : { p | paused : Bool }, jobs : RemoteData.WebData (List (JobBuilds j)) } -> Concourse.PipelineStatus
lastPipelineStatus { pipeline, jobs } =
    if pipeline.paused == True then
        Concourse.PipelineStatusPaused
    else
        case jobs of
            RemoteData.Success js ->
                lastPipelineStatusFromJobs js

            _ ->
                Concourse.PipelineStatusPending


lastPipelineStatusFromJobs : List (JobBuilds j) -> Concourse.PipelineStatus
lastPipelineStatusFromJobs jobs =
    let
        statuses =
            collectStatusesFromJobs jobs
    in
        if containsStatus Concourse.BuildStatusPending statuses then
            Concourse.PipelineStatusPending
        else if containsStatus Concourse.BuildStatusFailed statuses then
            Concourse.PipelineStatusFailed
        else if containsStatus Concourse.BuildStatusErrored statuses then
            Concourse.PipelineStatusErrored
        else if containsStatus Concourse.BuildStatusAborted statuses then
            Concourse.PipelineStatusAborted
        else if containsStatus Concourse.BuildStatusSucceeded statuses then
            Concourse.PipelineStatusSucceeded
        else
            Concourse.PipelineStatusPending


pipelineStatusFromJobs : List (JobBuilds j) -> Concourse.PipelineStatus
pipelineStatusFromJobs jobs =
    let
        statuses =
            collectStatusesFromJobs jobs
    in
        if containsStatus Concourse.BuildStatusPending statuses then
            Concourse.PipelineStatusPending
        else if List.any (\job -> job.nextBuild /= Nothing) jobs then
            Concourse.PipelineStatusRunning
        else if containsStatus Concourse.BuildStatusFailed statuses then
            Concourse.PipelineStatusFailed
        else if containsStatus Concourse.BuildStatusErrored statuses then
            Concourse.PipelineStatusErrored
        else if containsStatus Concourse.BuildStatusAborted statuses then
            Concourse.PipelineStatusAborted
        else if containsStatus Concourse.BuildStatusSucceeded statuses then
            Concourse.PipelineStatusSucceeded
        else
            Concourse.PipelineStatusPending


collectStatusesFromJobs : List (JobBuilds j) -> List (Maybe Concourse.BuildStatus)
collectStatusesFromJobs jobs =
    List.concatMap
        (\job ->
            [ Maybe.map .status job.finishedBuild
            , Maybe.map .status job.nextBuild
            ]
        )
        jobs


containsStatus : Concourse.BuildStatus -> List (Maybe Concourse.BuildStatus) -> Bool
containsStatus status statuses =
    List.any
        (\s ->
            case s of
                Just s ->
                    status == s

                Nothing ->
                    False
        )
        statuses


fetchPipelines : Cmd Msg
fetchPipelines =
    Cmd.map PipelinesResponse <|
        RemoteData.asCmd Concourse.Pipeline.fetchPipelines


fetchJobs : Concourse.Pipeline -> Cmd Msg
fetchJobs pipeline =
    Cmd.map (JobsResponse pipeline.id) <|
        RemoteData.asCmd <|
            Concourse.Job.fetchJobsWithTransitionBuilds
                { teamName = pipeline.teamName
                , pipelineName = pipeline.name
                }


fetchVersion : Cmd Msg
fetchVersion =
    Concourse.Info.fetch
        |> Task.map (.version)
        |> Task.attempt VersionFetched


getCurrentTime : Cmd Msg
getCurrentTime =
    Task.perform ClockTick Time.now


filterModelPipelines : String -> Model -> List Concourse.Pipeline
filterModelPipelines query model =
    let
        querySplit =
            String.split " " query
    in
        case model.pipelines of
            RemoteData.Success pipelines ->
                searchTermList model querySplit pipelines

            _ ->
                []


searchTermList : Model -> List String -> List Concourse.Pipeline -> List Concourse.Pipeline
searchTermList model queryList pipelines =
    case queryList of
        [] ->
            pipelines

        x :: xs ->
            let
                plist =
                    extendedPipelineList model pipelines
            in
                searchTermList model xs (filterBy x plist)


extendedPipelineList : Model -> List Concourse.Pipeline -> List StatusPipeline
extendedPipelineList model pipelines =
    let
        pipelineStates =
            getPipelineStates model pipelines

        setPipelineStatus p =
            pipelineStatus p |> Concourse.PipelineStatus.show
    in
        List.map
            (\p ->
                { pipeline = p.pipeline
                , status = setPipelineStatus p
                }
            )
            pipelineStates


filterBy : String -> List StatusPipeline -> List Concourse.Pipeline
filterBy term pipelines =
    let
        searchTeams =
            String.startsWith "team:" term

        searchStatus =
            String.startsWith "status:" term

        teamSearchTerm =
            if searchTeams then
                String.dropLeft 5 term
            else
                term

        statusSearchTerm =
            if searchStatus then
                String.dropLeft 7 term
            else
                term

        plist =
            List.map (\p -> p.pipeline) pipelines

        filterByStatus =
            Simple.Fuzzy.filter .status statusSearchTerm pipelines
    in
        if searchTeams == True then
            Simple.Fuzzy.filter .teamName teamSearchTerm plist
        else if searchStatus == True then
            List.map (\p -> p.pipeline) filterByStatus
        else
            Simple.Fuzzy.filter .name term plist


getPipelineStates : Model -> List Concourse.Pipeline -> List PipelineWithJobs
getPipelineStates model pipelines =
    List.filter ((/=) RemoteData.NotAsked << .jobs) <|
        List.map
            (\pipeline ->
                { pipeline = pipeline
                , jobs =
                    Maybe.withDefault RemoteData.NotAsked <|
                        Dict.get pipeline.id model.jobs
                }
            )
            pipelines
