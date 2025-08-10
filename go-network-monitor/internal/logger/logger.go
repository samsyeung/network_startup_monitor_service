package logger

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Logger provides structured logging with rotation
type Logger struct {
	file         *os.File
	logPath      string
	mu           sync.Mutex
	messageCount int
}

// New creates a new logger instance
func New(logPath string) (*Logger, error) {
	err := os.MkdirAll(filepath.Dir(logPath), 0755)
	if err != nil {
		return nil, fmt.Errorf("failed to create log directory: %w", err)
	}
	
	file, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open log file: %w", err)
	}
	
	return &Logger{
		file:    file,
		logPath: logPath,
	}, nil
}

// Log writes a log message with timestamp
func (l *Logger) Log(message string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	
	l.messageCount++
	
	// Check for log rotation every 10 messages
	if l.messageCount%10 == 0 {
		l.rotateIfNeeded()
	}
	
	timestamp := time.Now().Format("2006-01-02 15:04:05.000")
	logLine := fmt.Sprintf("%s - %s\n", timestamp, message)
	
	// Write to both file and stdout
	l.file.WriteString(logLine)
	l.file.Sync()
	fmt.Print(logLine)
}

// Logf writes a formatted log message
func (l *Logger) Logf(format string, args ...interface{}) {
	l.Log(fmt.Sprintf(format, args...))
}

// Banner logs a startup banner with configuration details
func (l *Logger) Banner(pid int, mode string, totalTimeout, afterSuccess, sleep time.Duration, interfaceTypes []string, resolver string, pingTimeout, dnsTimeout time.Duration) {
	l.Log("=============================================================")
	l.Logf("    NETWORK STARTUP MONITOR SERVICE - %s", time.Now().Format(time.RFC3339))
	l.Log("=============================================================")
	l.Logf("PID: %d", pid)
	l.Logf("Mode: %s", mode)
	l.Logf("Timeouts: Total=%s, AfterSuccess=%s, Sleep=%s", totalTimeout, afterSuccess, sleep)
	l.Logf("Interface Types: %s", strings.Join(interfaceTypes, " "))
	l.Logf("DNS Resolver: %s (timeout: %s)", resolver, dnsTimeout)
	l.Logf("Ping Timeout: %s", pingTimeout)
	l.Log("=============================================================")
}

// rotateIfNeeded checks if log rotation is needed and performs it
func (l *Logger) rotateIfNeeded() {
	const maxSizeMB = 10
	const maxArchives = 5
	
	stat, err := l.file.Stat()
	if err != nil {
		return
	}
	
	sizeMB := stat.Size() / (1024 * 1024)
	if sizeMB < maxSizeMB {
		return
	}
	
	// Close current file
	l.file.Close()
	
	// Rotate logs
	timestamp := time.Now().Format("20060102_150405")
	archivedLog := fmt.Sprintf("%s.%s", l.logPath, timestamp)
	
	err = os.Rename(l.logPath, archivedLog)
	if err != nil {
		log.Printf("Failed to rotate log: %v", err)
		return
	}
	
	// Create new log file
	newFile, err := os.OpenFile(l.logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		log.Printf("Failed to create new log file: %v", err)
		return
	}
	
	l.file = newFile
	l.Log(fmt.Sprintf("Log rotated: %s (%dMB)", archivedLog, sizeMB))
	
	// Clean up old archives
	l.cleanupOldArchives(maxArchives)
}

// cleanupOldArchives removes old log archive files
func (l *Logger) cleanupOldArchives(maxArchives int) {
	logDir := filepath.Dir(l.logPath)
	logBasename := filepath.Base(l.logPath)
	
	files, err := os.ReadDir(logDir)
	if err != nil {
		return
	}
	
	var archives []os.FileInfo
	for _, file := range files {
		if strings.HasPrefix(file.Name(), logBasename+".") {
			info, err := file.Info()
			if err == nil {
				archives = append(archives, info)
			}
		}
	}
	
	// Sort by modification time (newest first)
	// Keep only the most recent maxArchives files
	if len(archives) > maxArchives {
		for i := maxArchives; i < len(archives); i++ {
			oldPath := filepath.Join(logDir, archives[i].Name())
			if err := os.Remove(oldPath); err == nil {
				l.Log(fmt.Sprintf("Removed old archive: %s", oldPath))
			}
		}
	}
}

// Close closes the logger
func (l *Logger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	
	if l.file != nil {
		return l.file.Close()
	}
	return nil
}