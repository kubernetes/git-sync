package logging

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"

	"github.com/go-logr/glogr"
	"github.com/go-logr/logr"
)

// A logger embeds logr.Logger
type Logger struct {
	log       logr.Logger
	root      string
	errorFile string
}

// NewLogger returns glogr implemented logr.Logger.
func NewLogger(root string, errorFile string) *Logger {
	return &Logger{log: glogr.New(), root: root, errorFile: errorFile}
}

// Info implements logr.Logger.Info.
func (l *Logger) Info(msg string, keysAndValues ...interface{}) {
	l.log.Info(msg, keysAndValues...)
}

// Error implements logr.Logger.Error.
func (l *Logger) Error(err error, msg string, kvList ...interface{}) {
	l.log.Error(err, msg, kvList...)
	if l.errorFile == "" {
		return
	}
	payload := struct {
		Msg  string
		Err  string
		Args map[string]interface{}
	}{
		Msg:  msg,
		Err:  err.Error(),
		Args: map[string]interface{}{},
	}
	if len(kvList)%2 != 0 {
		kvList = append(kvList, "<no-value>")
	}
	for i := 0; i < len(kvList); i += 2 {
		k, ok := kvList[i].(string)
		if !ok {
			k = fmt.Sprintf("%v", kvList[i])
		}
		payload.Args[k] = kvList[i+1]
	}
	jb, err := json.Marshal(payload)
	if err != nil {
		l.log.Error(err, "can't encode error payload")
		content := fmt.Sprintf("%v", err)
		l.writeContent([]byte(content))
	} else {
		l.writeContent(jb)
	}
}

// V implements logr.Logger.V.
func (l *Logger) V(level int) logr.Logger {
	return l.log.V(level)
}

// WithValues implements logr.Logger.WithValues.
func (l *Logger) WithValues(keysAndValues ...interface{}) logr.Logger {
	return l.log.WithValues(keysAndValues...)
}

// WithName implements logr.Logger.WithName.
func (l *Logger) WithName(name string) logr.Logger {
	return l.log.WithName(name)
}

// ExportError exports the error to the error file if --export-error is enabled.
func (l *Logger) ExportError(content string) {
	if l.errorFile == "" {
		return
	}
	l.writeContent([]byte(content))
}

// DeleteErrorFile deletes the error file.
func (l *Logger) DeleteErrorFile() {
	if l.errorFile == "" {
		return
	}
	errorFile := filepath.Join(l.root, l.errorFile)
	if err := os.Remove(errorFile); err != nil {
		if os.IsNotExist(err) {
			return
		}
		l.log.Error(err, "can't delete the error-file", "filename", errorFile)
	}
}

// writeContent writes the error content to the error file.
func (l *Logger) writeContent(content []byte) {
	if _, err := os.Stat(l.root); os.IsNotExist(err) {
		fileMode := os.FileMode(0755)
		if err := os.Mkdir(l.root, fileMode); err != nil {
			l.log.Error(err, "can't create the root directory", "root", l.root)
			return
		}
	}
	tmpFile, err := ioutil.TempFile(l.root, "tmp-err-")
	if err != nil {
		l.log.Error(err, "can't create temporary error-file", "directory", l.root, "prefix", "tmp-err-")
		return
	}
	defer func() {
		if err := tmpFile.Close(); err != nil {
			l.log.Error(err, "can't close temporary error-file", "filename", tmpFile.Name())
		}
	}()

	if _, err = tmpFile.Write(content); err != nil {
		l.log.Error(err, "can't write to temporary error-file", "filename", tmpFile.Name())
		return
	}

	errorFile := filepath.Join(l.root, l.errorFile)
	if err := os.Rename(tmpFile.Name(), errorFile); err != nil {
		l.log.Error(err, "can't rename to error-file", "temp-file", tmpFile.Name(), "error-file", errorFile)
		return
	}
	if err := os.Chmod(errorFile, 0644); err != nil {
		l.log.Error(err, "can't change permissions on the error-file", "error-file", errorFile)
	}
}
