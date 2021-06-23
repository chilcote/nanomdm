// Pacakge nanomdm is an MDM service.
package nanomdm

import (
	"fmt"

	"github.com/micromdm/nanomdm/log"
	"github.com/micromdm/nanomdm/mdm"
	"github.com/micromdm/nanomdm/storage"
)

// Service is the main NanoMDM service which dispatches to storage.
type Service struct {
	logger     log.Logger
	normalizer func(e *mdm.Enrollment) *mdm.EnrollID
	store      storage.ServiceStore
}

// normalize generates enrollment IDs that are used by other
// services and the storage backend. Enrollment IDs need not
// necessarily be related to the UDID, UserIDs, or other identifiers
// sent in the request, but by convention that is what this normalizer
// uses.
//
// Device enrollments are identified by the UDID or EnrollmentID. User
// enrollments are then appended after a colon (":"). Note that the
// storage backends depend on the ParentID field matching a device
// enrollment so that the "parent" (device) enrollment can be
// referenced.
func normalize(e *mdm.Enrollment) *mdm.EnrollID {
	r := e.Resolved()
	if r == nil {
		return nil
	}
	eid := &mdm.EnrollID{
		Type: r.Type,
		ID:   r.DeviceChannelID,
	}
	if r.IsUserChannel {
		eid.ID += ":" + r.UserChannelID
		eid.ParentID = r.DeviceChannelID
	}
	return eid
}

type Option func(*Service)

func WithLogger(logger log.Logger) Option {
	return func(s *Service) {
		s.logger = logger
	}
}

// New returns a new NanoMDM main service.
func New(store storage.ServiceStore, opts ...Option) *Service {
	nanomdm := &Service{
		store:      store,
		logger:     log.NopLogger,
		normalizer: normalize,
	}
	for _, opt := range opts {
		opt(nanomdm)
	}
	return nanomdm
}

func (s *Service) updateEnrollID(r *mdm.Request, e *mdm.Enrollment) error {
	if r.EnrollID != nil && r.ID != "" {
		s.logger.Debug("msg", "overwriting enrollment id")
	}
	r.EnrollID = s.normalizer(e)
	return r.EnrollID.Validate()
}

// Authenticate Check-in message implementation.
func (s *Service) Authenticate(r *mdm.Request, message *mdm.Authenticate) error {
	if err := s.updateEnrollID(r, &message.Enrollment); err != nil {
		return err
	}
	logs := []interface{}{
		"msg", "Authenticate",
		"id", r.ID,
		"type", r.Type,
	}
	if message.SerialNumber != "" {
		logs = append(logs, "serial_number", message.SerialNumber)
	}
	s.logger.Info(logs...)
	if err := s.store.StoreAuthenticate(r, message); err != nil {
		return err
	}
	// clear the command queue for any enrollment or sub-enrollment.
	// this prevents queued commands still being queued after device
	// unenrollment.
	if err := s.store.ClearQueue(r); err != nil {
		return err
	}
	// then, disable the enrollment or any sub-enrollment (because an
	// enrollment is only valid after a tokenupdate)
	return s.store.Disable(r)
}

// TokenUpdate Check-in message implementation.
func (s *Service) TokenUpdate(r *mdm.Request, message *mdm.TokenUpdate) error {
	if err := s.updateEnrollID(r, &message.Enrollment); err != nil {
		return err
	}
	s.logger.Info(
		"msg", "TokenUpdate",
		"id", r.ID,
		"type", r.Type,
	)
	return s.store.StoreTokenUpdate(r, message)
}

// CheckOut Check-in message implementation.
func (s *Service) CheckOut(r *mdm.Request, message *mdm.CheckOut) error {
	if err := s.updateEnrollID(r, &message.Enrollment); err != nil {
		return err
	}
	s.logger.Info(
		"msg", "CheckOut",
		"id", r.ID,
		"type", r.Type,
	)
	return s.store.Disable(r)
}

func (s *Service) SetBootstrapToken(r *mdm.Request, message *mdm.SetBootstrapToken) error {
	if err := s.updateEnrollID(r, &message.Enrollment); err != nil {
		return err
	}
	s.logger.Info(
		"msg", "SetBootstrapToken",
		"id", r.ID,
		"type", r.Type,
	)
	return s.store.StoreBootstrapToken(r, message)
}

func (s *Service) GetBootstrapToken(r *mdm.Request, message *mdm.GetBootstrapToken) (*mdm.BootstrapToken, error) {
	if err := s.updateEnrollID(r, &message.Enrollment); err != nil {
		return nil, err
	}
	s.logger.Info(
		"msg", "GetBootstrapToken",
		"id", r.ID,
		"type", r.Type,
	)
	return s.store.RetrieveBootstrapToken(r, message)
}

// CommandAndReportResults command report and next-command request implementation.
func (s *Service) CommandAndReportResults(r *mdm.Request, results *mdm.CommandResults) (*mdm.Command, error) {
	if err := s.updateEnrollID(r, &results.Enrollment); err != nil {
		return nil, err
	}
	logs := []interface{}{
		"status", results.Status,
		"id", r.ID,
		"type", r.Type,
	}
	if results.Status != "Idle" {
		logs = append(logs, "command_uuid", results.CommandUUID)
	}
	s.logger.Info(logs...)
	err := s.store.StoreCommandReport(r, results)
	if err != nil {
		return nil, fmt.Errorf("storing command report: %w", err)
	}
	cmd, err := s.store.RetrieveNextCommand(r, results.Status == "NotNow")
	if err != nil {
		return nil, fmt.Errorf("retrieving next command: %w", err)
	}
	if cmd != nil {
		s.logger.Debug(
			"msg", "command retrieved",
			"id", r.ID,
			"command_uuid", cmd.CommandUUID,
		)
		return cmd, nil
	}
	s.logger.Debug(
		"msg", "no command retrieved",
		"id", r.ID,
	)
	return nil, nil
}
