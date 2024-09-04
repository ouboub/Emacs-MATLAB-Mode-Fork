function [out, docTopic] = help(varargin)
% Provide help, augmented so Emacs picks it up to display in a special buffer.
% See the help for the built-in help command by asking for "help help" in
% MATLAB, which will redirect to the correct location.

    me = [mfilename('fullpath'), '.m'];

    % Recursion detection, which should not occur, but be safe.
    [ST] = dbstack('-completenames',1);
    files = { ST.file };
    mask = strncmp(files, me, length(me));
    if any(mask)
        disp('MATLAB Emacs help override recursion detected.  Exiting.');
        return;
    end

    % Locate built-in help.m
    builtinHelp = '';
    helpLocations = which('-all', 'help.m');
    for idx = 1 : length(helpLocations)
        loc = helpLocations{idx};
        if (ispc && strcmpi(loc, me)) || (~ispc && strcmp(loc, me))
            continue % skip /path/to/Emacs-MATLAB-Mode/toolbox/help.m
        end
        builtinHelp = loc;
        break
    end
    assert(~isempty(builtinHelp));

    % Cd to where built-in help is so we call that first.  On cleanup restore orig working directory.
    builtinHelpDir = fileparts(builtinHelp);

    origCWD=pwd;
    cd(builtinHelpDir);
    cleanup = onCleanup(@()cd(origCWD));

    if ~strcmp(which('help'), builtinHelp)
        rehash path % force the builtin help to appear
        h = which('help');
        if ~strcmp(h, builtinHelp)
            error(['assert - failed to get built-in help, got: ', h, ' expected: ', builtinHelp]);
        end
    end

    args = varargin;

    nso = emacsnetshell('fetch');

    if isempty(nso)
        cookie = true;
    else
        cookie = false;
    end

    if nargin > 0 && strcmp(args{1}, '-emacs')
        cookie=false;
        args = args(2:end);
    end

    switch nargout
      case 0
        if cookie
            disp(['<EMACSCAP>(*MATLAB Help: ' args{:} '*)']);
        end
        try
            help(args{:});
        catch ERR
            disp(ERR)
        end
        if cookie
            disp('</EMACSCAP>');
        end
      case 1
        [out] = help(args{:});
      case 2
        [out, docTopic] = help(args{:});
    end
end
