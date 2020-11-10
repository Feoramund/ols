package server

import "core:strings"
import "core:fmt"
import "core:log"
import "core:os"
import "core:odin/parser"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:path"

import "shared:common"

ParserError :: struct {
    message: string,
    line: int,
    column: int,
    file: string,
    offset: int,
};


Package :: struct {
    documents: [dynamic]^Document,
};

Document :: struct {
    uri: common.Uri,
    text: [] u8,
    used_text: int, //allow for the text to be reallocated with more data than needed
    client_owned: bool,
    diagnosed_errors: bool,
    ast: ast.File,
    package_name: string,
    imports: [] string,
};

DocumentStorage :: struct {
    documents: map [string] Document,
    packages: map [string] Package,
};

document_storage: DocumentStorage;


document_get :: proc(uri_string: string) -> ^Document {

    uri, parsed_ok := common.parse_uri(uri_string, context.temp_allocator);

    if !parsed_ok {
        return nil;
    }

    return &document_storage.documents[uri.path];
}

/*
    Note(Daniel, Should there be reference counting of documents or just clear everything on workspace change?
        You usually always need the documents that are loaded in core files, your own files, etc.)
 */

/*
    Server opens a new document with text from filesystem
*/
document_new :: proc(path: string, config: ^common.Config) -> common.Error {

    text, ok := os.read_entire_file(path);

    uri := common.create_uri(path);

    if !ok {
        log.error("Failed to parse uri");
        return .ParseError;
    }

    document := Document {
        uri = uri,
        text = transmute([] u8)text,
        client_owned = false,
        used_text = len(text),
    };


    document_storage.documents[path] = document;

    return .None;
}

/*
    Client opens a document with transferred text
*/

document_open :: proc(uri_string: string, text: string, config: ^common.Config, writer: ^Writer) -> common.Error {

    uri, parsed_ok := common.parse_uri(uri_string);

    log.infof("document_open: %v", uri_string);

    if !parsed_ok {
        log.error("Failed to parse uri");
        return .ParseError;
    }

    if document := &document_storage.documents[uri.path]; document != nil {

        if document.client_owned {
            log.errorf("Client called open on an already open document: %v ", document.uri.path);
            return .InvalidRequest;
        }

        if document.text != nil {
            delete(document.text);
        }

        if len(document.uri.uri) > 0 {
            common.delete_uri(document.uri);
        }

        document.uri = uri;
        document.client_owned = true;
        document.text = transmute([] u8)text;
        document.used_text = len(document.text);

        if err := document_refresh(document, config, writer, true); err != .None {
            return err;
        }

    }

    else {

        document := Document {
            uri = uri,
            text = transmute([] u8)text,
            client_owned = true,
            used_text = len(text),
        };

        if err := document_refresh(&document, config, writer, true); err != .None {
            return err;
        }

        document_storage.documents[uri.path] = document;
    }



    //hmm feels like odin needs some ownership semantic
    delete(uri_string);

    return .None;
}

/*
    Function that applies changes to the given document through incremental syncronization
 */
document_apply_changes :: proc(uri_string: string, changes: [dynamic] TextDocumentContentChangeEvent, config: ^common.Config, writer: ^Writer) -> common.Error {

    uri, parsed_ok := common.parse_uri(uri_string, context.temp_allocator);

    if !parsed_ok {
        return .ParseError;
    }

    document := &document_storage.documents[uri.path];

    if !document.client_owned {
        log.errorf("Client called change on an document not opened: %v ", document.uri.path);
        return .InvalidRequest;
    }

    for change in changes {

        //for some reason sublime doesn't seem to care even if i tell it to do incremental sync
        if range, ok := change.range.(common.Range); ok {

            absolute_range, ok := common.get_absolute_range(range, document.text[:document.used_text]);

            if !ok {
                return .ParseError;
            }

            //lower bound is before the change
            lower := document.text[:absolute_range.start];

            //new change between lower and upper
            middle := change.text;

            //upper bound is after the change
            upper := document.text[absolute_range.end:document.used_text];

            //total new size needed
            document.used_text = len(lower) + len(change.text) + len(upper);

            //Reduce the amount of allocation by allocating more memory than needed
            if document.used_text > len(document.text) {
                new_text := make([]u8, document.used_text * 2);

                //join the 3 splices into the text
                copy(new_text, lower);
                copy(new_text[len(lower):], middle);
                copy(new_text[len(lower)+len(middle):], upper);

                delete(document.text);

                document.text = new_text;
            }

            else {
                //order matters here, we need to make sure we swap the data already in the text before the middle
                copy(document.text, lower);
                copy(document.text[len(lower)+len(middle):], upper);
                copy(document.text[len(lower):], middle);
            }

        }

        else {

            document.used_text = len(change.text);

            if document.used_text > len(document.text) {
                new_text := make([]u8, document.used_text * 2);
                copy(new_text, change.text);
                delete(document.text);
                document.text = new_text;
            }

            else {
                 copy(document.text, change.text);
            }

        }


    }

    return document_refresh(document, config, writer, true);
}

document_close :: proc(uri_string: string) -> common.Error {

    uri, parsed_ok := common.parse_uri(uri_string, context.temp_allocator);

    if !parsed_ok {
        return .ParseError;
    }

    document := &document_storage.documents[uri.path];

    if document == nil || !document.client_owned {
        log.errorf("Client called close on a document that was never opened: %v ", document.uri.path);
        return .InvalidRequest;
    }

    document.client_owned = false;

    delete(document.text);

    return .None;
}



document_refresh :: proc(document: ^Document, config: ^common.Config, writer: ^Writer, parse_imports: bool) -> common.Error {

    errors, ok := parse_document(document, config);

    if !ok {
        return .ParseError;
    }

    //right now we don't allow to writer errors out from files read from the file directory, core files, etc.
    if writer != nil && len(errors) > 0 {
        document.diagnosed_errors = true;

        params := NotificationPublishDiagnosticsParams {
            uri = document.uri.uri,
            diagnostics = make([] Diagnostic, len(errors), context.temp_allocator),
        };

        for error, i in errors {

            params.diagnostics[i] = Diagnostic {
                range = common.Range {
                    start = common.Position {
                        line = error.line - 1,
                        character = 0,
                    },
                    end = common.Position {
                        line = error.line,
                        character = 0,
                    },
                },
                severity = DiagnosticSeverity.Error,
                code = "test",
                message = error.message,
            };

        }

        notifaction := Notification {
            jsonrpc = "2.0",
            method = "textDocument/publishDiagnostics",
            params = params,
        };

        send_notification(notifaction, writer);

    }

    if writer != nil && len(errors) == 0 {

        //send empty diagnosis to remove the clients errors
        if document.diagnosed_errors {

            notifaction := Notification {
            jsonrpc = "2.0",
            method = "textDocument/publishDiagnostics",

            params = NotificationPublishDiagnosticsParams {
                uri = document.uri.uri,
                diagnostics = make([] Diagnostic, len(errors), context.temp_allocator),
                },
            };

            document.diagnosed_errors = false;

            send_notification(notifaction, writer);
        }

    }

    return .None;
}

document_load_package :: proc(package_directory: string, config: ^common.Config) -> common.Error {

    fd, err := os.open(package_directory);

    if err != 0 {
        return .ParseError;
    }

    files: []os.File_Info;
    files, err = os.read_dir(fd, 100, context.temp_allocator);

    for file in files {

        //if we have never encountered the document
        if _, ok := document_storage.documents[file.fullpath]; !ok {

            if doc_err := document_new(file.fullpath, config); doc_err != .None {
                return doc_err;
            }

        }

    }

    return .None;
}


current_errors: [dynamic] ParserError;

parser_error_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
    error := ParserError { line = pos.line, column = pos.column, file = pos.file,
                           offset = pos.offset, message = fmt.tprintf(msg, ..args) };
    append(&current_errors, error);
}

parser_warning_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {

}

parse_document :: proc(document: ^Document, config: ^common.Config) -> ([] ParserError, bool) {

    p := parser.Parser {
		err  = parser_error_handler,
		warn = parser_warning_handler,
	};

    current_errors = make([dynamic] ParserError, context.temp_allocator);

    document.ast = ast.File {
        fullpath = document.uri.path,
        src = document.text[:document.used_text],
    };

    parser.parse_file(&p, &document.ast);

    /*
    fmt.println();
    fmt.println();

    for decl in document.ast.decls {
        common.print_ast(decl, 0, document.ast.src);
    }

    fmt.println();
    fmt.println();
    */

    /*
    if document.imports != nil {
        delete(document.imports);
        delete(document.package_name);
    }
    document.imports = make([]string, len(document.ast.imports));
    document.package_name = document.ast.pkg_name;

    for imp, index in document.ast.imports {

        //collection specified
        if i := strings.index(imp.fullpath, ":"); i != -1 {

            collection := imp.fullpath[1:i];
            p := imp.fullpath[i+1:len(imp.fullpath)-1];

            dir, ok := config.collections[collection];

            if !ok {
                continue;
            }

            document.imports[index] = path.join(dir, p);

        }

        //relative
        else {

        }
    }
    */

    return current_errors[:], true;
}


free_ast_node :: proc(file: ^ast.Node) {

}