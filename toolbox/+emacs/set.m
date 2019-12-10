function set(varargin)
% Setup an Emacs option based on Name/Value pairs.
% Valid options include:
%
%  netshell - Initilize a netshell connection.
%  clientcmd - What to use for `edit' client command
    
    P = inputParser;
    addParameter(P, 'netshell', 0, @isnumeric)
    addParameter(P, 'clientcmd', "", @ischar)
    
    parse(P, varargin{:});
    
    clientcommand = P.Results.clientcmd;
    netshellport = P.Results.netshell;

    %% Client Command
    if ~isempty(clientcommand)
        if usejava('jvm')
            % Use clientcommand (e.g. emacsclient -n) for text editing
            com.mathworks.services.Prefs.setBooleanPref('EditorBuiltinEditor', false);
            com.mathworks.services.Prefs.setStringPref('EditorOtherEditor', clientcommand);
        end
    end

    %% Netshell Support
    if netshellport
    
        nso = emacsnetshell('init');

        % Assign netshell into our reporter objects.
        bp = getappdata(groot, 'EmacsBreakpoints');
        bp.NetShellObject = nso;
        
        st = getappdata(groot, 'EmacsStack');
        st.NetShellObject = nso;
    
    end
end

